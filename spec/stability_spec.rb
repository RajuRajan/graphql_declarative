# frozen_string_literal: true

# ---------------------------------------------------------------------------
# THE PROOF FOR THE README (SPEC.md §1b, §8).
#
# graphql-ruby's own cursors are offsets:
#
#   GraphQL::Pagination::RelationConnection#cursor_for
#     def cursor_for(item)
#       offset = ... index_of(item) ...
#       encode(offset.to_s)
#     end
#
# An offset only means anything relative to a result set that has not changed.
# Insert or delete a row BEFORE the current page while a client is paginating
# and every later cursor points one place off: records repeat, or vanish.
# Static fixtures never catch it, because nothing is inserted mid-pagination.
#
# This file inserts and deletes rows mid-pagination and asserts BOTH sides:
#   * the keyset connection returns exactly the unseen records;
#   * the offset connection does not — and that wrong behaviour is asserted
#     explicitly, so the contrast is executable and cannot silently regress.
# ---------------------------------------------------------------------------

RSpec.describe "cursor stability under concurrent writes" do
  # --- one course type, two schemas over it --------------------------------

  course_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "StabilityCourse"
    field :id, GraphQL::Types::ID, null: false
    field :title, GraphQL::Types::String
  end

  # (1) The gem. Keyset cursors, (title, id).
  keyset_resolver = Class.new(GraphqlDeclarative::Resolver) do
    graphql_name "StabilityCoursesResolver"
    type course_type.connection_type, null: false

    sortable_by :title
    # `cursor: :title` makes title the default sort, so both schemas below
    # paginate the same order and only the cursor scheme differs.
    paginate cursor: :title, default_page_size: 2, max_page_size: 10

    def base_scope
      Course.all
    end
  end

  keyset_query = Class.new(GraphQL::Schema::Object) do
    graphql_name "StabilityKeysetQuery"
    field :courses, resolver: keyset_resolver
  end

  # (2) The baseline: a plain relation field, wrapped by graphql-ruby's own
  # RelationConnection. Same data, same order, offset cursors.
  offset_query = Class.new(GraphQL::Schema::Object) do
    graphql_name "StabilityOffsetQuery"
    field :courses, course_type.connection_type, null: false

    define_method(:courses) { Course.order(:title, :id) }
  end

  const_set(:KEYSET_SCHEMA, Class.new(GraphQL::Schema) { query keyset_query })
  const_set(:OFFSET_SCHEMA, Class.new(GraphQL::Schema) { query offset_query })

  # Identical text against both schemas: same field, same arguments, same
  # selection. The only thing that differs between the two runs is what a
  # `cursor` means.
  def query_string
    <<~GQL
      query($first: Int, $after: String) {
        courses(first: $first, after: $after) {
          edges { cursor node { title } }
        }
      }
    GQL
  end

  def keyset(first:, after: nil)
    run(self.class.const_get(:KEYSET_SCHEMA), first: first, after: after)
  end

  def offset(first:, after: nil)
    run(self.class.const_get(:OFFSET_SCHEMA), first: first, after: after)
  end

  def run(schema, first:, after:)
    result = schema.execute(query_string, variables: {"first" => first, "after" => after})
    raise result["errors"].inspect if result["errors"]
    edges = result.dig("data", "courses", "edges")
    {titles: edges.map { |e| e.dig("node", "title") }, cursor: edges.last&.fetch("cursor")}
  end

  # B D F H J L — gaps left on purpose so an inserted row can land before,
  # inside or after the current page.
  let!(:courses) { %w[B D F H J L].map { |t| Course.create!(title: t) } }

  # --- what the two cursor schemes actually contain -------------------------

  describe "what a cursor encodes" do
    it "graphql-ruby encodes an OFFSET" do
      page1 = offset(first: 2)

      expect(Base64.decode64(page1[:cursor])).to eq("2")
    end

    it "this gem encodes the key tuple (sort_value, id)" do
      page1 = keyset(first: 2)
      payload = GraphqlDeclarative::Cursor.decode(page1[:cursor])

      expect(payload[:sort_value]).to eq("D")
      expect(payload[:id]).to eq(courses[1].id)
    end

    it "a keyset cursor is independent of how many rows precede the row" do
      before_insert = keyset(first: 2)[:cursor]
      Course.create!(title: "A")
      after_insert = keyset(first: 3)[:cursor]

      # After inserting "A", page 1 of size 3 is A B D — "D" is now at a
      # different offset but has the same cursor, because the cursor is about
      # the row, not about its position.
      expect(after_insert).to eq(before_insert)
    end
  end

  # --- INSERT before the current page --------------------------------------

  describe "a row is INSERTED before the current page, mid-pagination" do
    it "keyset: page 2 is exactly the unseen records" do
      page1 = keyset(first: 2)
      expect(page1[:titles]).to eq(%w[B D])

      Course.create!(title: "A") # sorts before everything the client has seen

      page2 = keyset(first: 2, after: page1[:cursor])

      expect(page2[:titles]).to eq(%w[F H])
      expect(page1[:titles] & page2[:titles]).to be_empty
    end

    it "offset: page 2 REPEATS a record the client already saw (the bug)" do
      page1 = offset(first: 2)
      expect(page1[:titles]).to eq(%w[B D])

      Course.create!(title: "A")

      page2 = offset(first: 2, after: page1[:cursor])

      # Asserting the WRONG behaviour on purpose. The cursor says "offset 2";
      # with "A" inserted, offset 2 is now "D", which page 1 already returned.
      expect(page2[:titles]).to eq(%w[D F])
      expect(page1[:titles] & page2[:titles]).to eq(%w[D])
    end

    it "keyset walks the whole set exactly once despite the insert" do
      seen = []
      cursor = nil
      inserted = false

      loop do
        page = keyset(first: 2, after: cursor)
        break if page[:titles].empty?

        seen.concat(page[:titles])
        cursor = page[:cursor]

        unless inserted
          Course.create!(title: "A") # slipped in after page 1
          inserted = true
        end
      end

      # "A" is never seen — it sorts before the cursor, and a forward walk that
      # has already passed that point is not supposed to go back for it. What
      # matters is that nothing is repeated and nothing originally present is
      # skipped.
      expect(seen).to eq(%w[B D F H J L])
      expect(seen.uniq).to eq(seen)
    end
  end

  # --- DELETE before the current page --------------------------------------

  describe "a row is DELETED before the current page, mid-pagination" do
    it "keyset: page 2 is still exactly the unseen records" do
      page1 = keyset(first: 2)
      expect(page1[:titles]).to eq(%w[B D])

      Course.find_by(title: "B").destroy # a row the client already saw

      page2 = keyset(first: 2, after: page1[:cursor])

      expect(page2[:titles]).to eq(%w[F H])
    end

    it "offset: page 2 SKIPS a record that was never shown (the bug)" do
      page1 = offset(first: 2)
      expect(page1[:titles]).to eq(%w[B D])

      Course.find_by(title: "B").destroy

      page2 = offset(first: 2, after: page1[:cursor])

      # Asserting the WRONG behaviour on purpose. Offset 2 in the new result set
      # is "H"; "F" is never returned to the client at all.
      expect(page2[:titles]).to eq(%w[H J])
      expect(page2[:titles]).not_to include("F")
    end
  end

  # --- the same, with a non-unique sort column -----------------------------

  describe "ties, where the :id tiebreaker earns its keep" do
    let!(:tied) { 3.times.map { Course.create!(title: "M") } }

    it "keyset does not repeat or skip tied rows across a page boundary" do
      page1 = keyset(first: 2, after: GraphqlDeclarative::Cursor.encode(sort_value: "L", id: courses.last.id))
      page2 = keyset(first: 2, after: page1[:cursor])

      expect(page1[:titles]).to eq(%w[M M])
      expect(page2[:titles]).to eq(%w[M])
    end

    it "keyset ids across the tie boundary are distinct and in order" do
      first_two = keyset(first: 2, after: GraphqlDeclarative::Cursor.encode(sort_value: "L", id: courses.last.id))
      cursor_payload = GraphqlDeclarative::Cursor.decode(first_two[:cursor])

      expect(cursor_payload[:sort_value]).to eq("M")
      expect(cursor_payload[:id]).to eq(tied[1].id)
    end
  end
end
