# frozen_string_literal: true

# ---------------------------------------------------------------------------
# KeysetConnection (SPEC.md §6.5).
#
# has_next_page is answered by fetching page_size + 1 rows and seeing whether
# the extra one came back. No COUNT: an unbounded count over a filtered set is
# a second, unbounded query, and it is the thing this design avoids.
#
# page_size is [first || default_page_size, max_page_size].min. A `first:` above
# the maximum is CLAMPED, not an error — a client asking for too much gets the
# most it is allowed, not a failure.
# ---------------------------------------------------------------------------

RSpec.describe GraphqlDeclarative::KeysetConnection do
  def connection(items, **kwargs)
    described_class.new(items, context: nil, **kwargs)
  end

  describe "has_next_page via the +1 row" do
    let!(:courses) { 5.times.map { |i| Course.create!(title: "Course #{i}") } }
    let(:scope) { Course.order(:id) }

    it "is true when more rows exist than fit on the page" do
      conn = connection(scope, first: 2)

      expect(conn.nodes.size).to eq(2)
      expect(conn.has_next_page).to be(true)
    end

    it "is false when the page exactly exhausts the relation" do
      conn = connection(scope, first: 5)

      expect(conn.nodes.size).to eq(5)
      expect(conn.has_next_page).to be(false)
    end

    it "is false when the relation is shorter than the page" do
      conn = connection(scope, first: 25)

      expect(conn.nodes.size).to eq(5)
      expect(conn.has_next_page).to be(false)
    end

    it "is false for an empty relation" do
      conn = connection(Course.where(title: "nothing"), first: 2)

      expect(conn.nodes).to eq([])
      expect(conn.has_next_page).to be(false)
    end

    it "never leaks the extra row into nodes" do
      conn = connection(scope, first: 3)

      expect(conn.nodes.map(&:id)).to eq(courses.first(3).map(&:id))
    end

    it "issues ONE query, LIMIT page_size + 1, and no COUNT" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name] == "SCHEMA" || payload[:sql] =~ /\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/
        statements << [payload[:sql], (payload[:binds] || []).map(&:value)]
      end

      conn = connection(scope, first: 2)
      conn.nodes
      conn.has_next_page

      ActiveSupport::Notifications.unsubscribe(subscriber)

      selects = statements.select { |sql, _| sql.include?("SELECT") }
      expect(selects.size).to eq(1)

      sql, binds = selects.first
      expect(sql).to include("LIMIT")
      # page_size 2 + 1. The extra row is the whole has_next_page mechanism.
      expect(binds.last).to eq(3)
      expect(sql).not_to match(/COUNT\(/i)
    end

    it "loads the page once, however many times it is asked" do
      conn = connection(scope, first: 2)
      first_call = conn.nodes

      expect(conn.nodes).to equal(first_call)
      expect(conn.has_next_page).to be(true)
    end

    it "works on a plain Array the caller already bounded to page_size + 1" do
      limit = described_class.page_size_for(first: 2)
      conn = connection(scope.limit(limit + 1).to_a, first: 2)

      expect(conn.nodes.size).to eq(2)
      expect(conn.has_next_page).to be(true)
    end
  end

  describe "page_size clamping" do
    it "uses default_page_size when `first:` is absent" do
      expect(connection(Course.all, default_page_size: 10, max_page_size: 100).page_size).to eq(10)
    end

    it "uses `first:` when it is under the maximum" do
      expect(connection(Course.all, first: 7, default_page_size: 25, max_page_size: 100).page_size).to eq(7)
    end

    it "clamps a `first:` above max_page_size instead of raising" do
      conn = connection(Course.all, first: 5000, default_page_size: 25, max_page_size: 100)

      expect(conn.page_size).to eq(100)
    end

    it "clamps a default_page_size that exceeds max_page_size too" do
      conn = connection(Course.all, default_page_size: 500, max_page_size: 100)

      expect(conn.page_size).to eq(100)
    end

    it "falls back to the documented defaults outside a query context" do
      expect(connection(Course.all).page_size).to eq(described_class::DEFAULT_PAGE_SIZE)
    end

    it "actually limits the fetch to the clamped size" do
      6.times { |i| Course.create!(title: "C#{i}") }
      conn = connection(Course.order(:id), first: 100, max_page_size: 3)

      expect(conn.nodes.size).to eq(3)
      expect(conn.has_next_page).to be(true)
    end

    describe ".page_size_for" do
      it "is the same arithmetic, exposed for callers that fetch themselves" do
        expect(described_class.page_size_for(first: 5, default_page_size: 25, max_page_size: 100)).to eq(5)
        expect(described_class.page_size_for(first: 500, default_page_size: 25, max_page_size: 100)).to eq(100)
        expect(described_class.page_size_for(default_page_size: 25, max_page_size: 100)).to eq(25)
      end

      it "raises rather than silently clamping a negative first: to 0" do
        # A page_size of 0 would still fetch page_size + 1 == 1 row, report
        # has_next_page: true off that extra row, and trim nodes to [] — a
        # page with no rows and no cursor to advance from. Reject instead.
        expect { described_class.page_size_for(first: -3) }
          .to raise_error(GraphQL::ExecutionError, /first:/)
      end
    end
  end

  describe "cursors" do
    let!(:beta) { Course.create!(title: "Beta") }
    let!(:alpha) { Course.create!(title: "Alpha") }

    it "encodes the key tuple, not the offset" do
      conn = connection(Course.order(:title), sort_column: :title, first: 2)
      cursors = conn.nodes.map { |node| conn.cursor_for(node) }

      expect(cursors.uniq.size).to eq(2)
      expect(GraphqlDeclarative::Cursor.decode(cursors.first))
        .to eq(sort_value: "Alpha", id: alpha.id)
    end

    it "is a pure function of the item, not of the item's position in `nodes`" do
      # `cursor_for(item)` reads only `item[sort_column]` and `item.id` — it
      # never consults `nodes`/`items` at all, which is the actual property
      # that makes keyset cursors position-independent (see stability_spec.rb
      # for the end-to-end proof under concurrent writes). A test that just
      # compares two connections built from relations where `beta` happens to
      # carry the same title/id in both cannot fail: cursor_for would return
      # the same string even if a regression made it read from `nodes` again,
      # as long as `beta` were still IN `nodes` at the same computed offset.
      #
      # This instead calls cursor_for on a row that both connections show is
      # NOT present in their own `nodes` — `beta`'s "position" is nil in each
      # — and still gets the correct, matching cursor. A regression that
      # reintroduced an offset (e.g. `nodes.index(item)`) would return a
      # cursor built from a nil/garbage offset here, or raise, not the real
      # (title, id) tuple.
      empty = connection(Course.where(title: "nowhere"), sort_column: :title)
      other_page = connection(Course.where(title: "Alpha").order(:title), sort_column: :title)

      expect(empty.nodes).to eq([])
      expect(other_page.nodes.map(&:id)).not_to include(beta.id)

      expected = GraphqlDeclarative::Cursor.encode(sort_value: "Beta", id: beta.id)
      expect(empty.cursor_for(beta)).to eq(expected)
      expect(other_page.cursor_for(beta)).to eq(expected)
    end

    it "defaults the sort column to :id" do
      conn = connection(Course.order(:id))

      expect(GraphqlDeclarative::Cursor.decode(conn.cursor_for(beta)))
        .to eq(sort_value: beta.id, id: beta.id)
    end
  end

  describe "has_previous_page" do
    it "is always false — v0.1.0 is forward-only, and says so" do
      expect(connection(Course.all).has_previous_page).to be(false)
      expect(connection(Course.all, first: 1, after: "anything").has_previous_page).to be(false)
    end
  end

  describe "preloading" do
    let!(:courses) do
      3.times.map do |i|
        author = Author.create!(name: "Author #{i}")
        Course.create!(title: "Course #{i}", author: author)
      end
    end

    it "runs the preloader on the BOUNDED page, not the whole relation" do
      # Invariant 1 in SPEC.md §5. Preloading before LIMIT preloads the entire
      # filtered set — which on a big table is the bug the gem exists to avoid.
      seen = nil
      preloader = ->(records) { seen = records.dup }

      conn = connection(Course.order(:id), first: 1, preloader: preloader)
      conn.nodes

      expect(seen.size).to eq(1)
    end

    it "does not call the preloader for an empty page" do
      called = false
      conn = connection(Course.where(title: "nothing"), preloader: ->(_) { called = true })
      conn.nodes

      expect(called).to be(false)
    end
  end
end
