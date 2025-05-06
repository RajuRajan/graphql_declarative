# frozen_string_literal: true

# ---------------------------------------------------------------------------
# MISSING COVERAGE: a model whose primary key is not `id`, walked across real
# pages through a real GraphQL schema (SPEC.md §6.3/§6.4).
#
# `Widget` (spec/support/schema.rb) has `id: false` and a `uuid` primary key.
# Sort's ORDER BY tiebreaker and Cursor's seek predicate must both resolve the
# tiebreaker from `model.primary_key`, whatever it is named — if either one
# were still hardcoded to `:id`, this would either raise (no such column) or,
# on SQLite, silently and wrongly fall back to rowid. Only a full pagination
# walk through real cursors proves both halves stayed in sync end to end;
# sort_spec.rb/cursor_spec.rb already prove each half alone (SQL string /
# predicate shape), this is the thing that would actually break in
# production.
# ---------------------------------------------------------------------------

RSpec.describe "pagination over a model with a non-id primary key" do
  widget_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "CustomPkWidget"
    field :uuid, GraphQL::Types::String, null: false
    field :name, GraphQL::Types::String, null: false
  end

  widgets_resolver = Class.new(GraphqlDeclarative::Resolver) do
    graphql_name "CustomPkWidgetsResolver"
    type widget_type.connection_type, null: false

    sortable_by :name
    paginate default_page_size: 2, max_page_size: 10

    def base_scope
      Widget.all
    end
  end

  query_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "CustomPkQuery"
    field :widgets, resolver: widgets_resolver
  end

  schema = Class.new(GraphQL::Schema) { query query_type }
  const_set(:SCHEMA, schema)

  let!(:widgets) do
    # Two rows share a `name` ("alpha"), inserted in the OPPOSITE order their
    # uuids sort in, and everything else is inserted out of uuid order too.
    # This is deliberate: it makes the tiebreaker load-bearing rather than
    # incidental. If the tiebreaker ever fell back to a nonexistent `id`
    # column (SQLite silently aliases that to rowid — insertion order), the
    # "alpha" tie would come back as [w5, w1] instead of the correct,
    # uuid-ordered [w1, w5], and the walk assertion below would visibly fail
    # rather than passing by coincidence.
    [["w5", "alpha"], ["w3", "delta"], ["w1", "alpha"], ["w6", "echo"], ["w4", "bravo"], ["w2", "foxtrot"]]
      .map { |uuid, name| Widget.create!(uuid: uuid, name: name) }
  end

  def execute(query_string, variables: {})
    result = self.class.const_get(:SCHEMA).execute(query_string, variables: variables)
    raise result["errors"].inspect if result["errors"]
    result
  end

  it "orders by the whitelisted column with `uuid`, not `id`, as the tiebreaker" do
    sql = GraphqlDeclarative::Sort.apply(Widget.all, allowed: [:name], field: :name, direction: :asc).to_sql

    expect(sql).to match(/ORDER BY "widgets"\."name" ASC, "widgets"\."uuid" ASC/)
  end

  it "walks every page in order via real cursors, recovering the full table" do
    query = <<~GQL
      query($after: String) {
        widgets(first: 2, after: $after, sortBy: NAME) {
          pageInfo { hasNextPage }
          edges { cursor node { uuid name } }
        }
      }
    GQL

    seen = []
    cursor = nil

    # Bounded rather than an unconditional `loop`, so a pagination bug that
    # makes hasNextPage stick at true fails the example instead of hanging.
    (widgets.size + 1).times do
      result = execute(query, variables: {"after" => cursor})
      page = result.dig("data", "widgets", "edges")
      seen.concat(page.map { |e| e.dig("node", "uuid") })

      break unless result.dig("data", "widgets", "pageInfo", "hasNextPage")
      cursor = page.last["cursor"]
    end

    # order(:name, :uuid), not just order(:name): the gem's own contract
    # (SPEC.md §6.3) is "name ASC, tiebreak by the primary key ASC", so that
    # is the expectation to hold it to — plain `order(:name)` leaves SQLite
    # free to break the "alpha" tie any way it likes (in practice, insertion
    # order), which is a different, weaker guarantee than the one this test
    # exists to prove.
    expect(seen).to eq(Widget.order(:name, :uuid).pluck(:uuid))
    expect(seen.uniq.size).to eq(widgets.size) # no duplicates
    expect(seen.size).to eq(widgets.size) # nothing lost
  end

  it "issues a cursor whose id half is the uuid, not a numeric offset or an :id that doesn't exist" do
    result = execute("{ widgets(first: 1, sortBy: NAME) { edges { cursor node { uuid } } } }")
    edge = result.dig("data", "widgets", "edges").first

    decoded = GraphqlDeclarative::Cursor.decode(edge["cursor"])
    expect(decoded[:id]).to eq(edge.dig("node", "uuid"))
    expect(decoded[:id]).to eq("w1") # the "alpha" tie, broken by uuid ASC
    expect(decoded[:sort_value]).to eq("alpha")
  end
end
