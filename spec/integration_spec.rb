# frozen_string_literal: true

# ---------------------------------------------------------------------------
# THE N+1 PROOF.
#
# A real GraphQL schema, a real query, and an assertion on the QUERY COUNT
# rather than on the result shape. Result-shape tests pass just as happily with
# 200 queries as with 3, which is why N+1s survive test suites.
#
# The count is asserted as an exact number and then asserted again with more
# rows in the table: the number must not move. That invariance — constant
# queries as the data grows — is the actual property. See SPEC.md §8.
# ---------------------------------------------------------------------------

RSpec.describe "integration" do
  # --- query counting ------------------------------------------------------

  # Counts real SELECTs. Schema introspection and transaction control are not
  # part of what a resolver costs, so they are excluded.
  def count_queries
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      next if payload[:name] == "SCHEMA" || payload[:cached]
      next if /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i.match?(sql)
      statements << sql
    end

    yield

    ActiveSupport::Notifications.unsubscribe(subscriber)
    statements
  end

  # --- schema --------------------------------------------------------------

  enrollment_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "IntegrationEnrollment"
    field :id, GraphQL::Types::ID, null: false
    field :status, GraphQL::Types::String
  end

  author_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "IntegrationAuthor"
    field :id, GraphQL::Types::ID, null: false
    field :name, GraphQL::Types::String
  end

  course_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "IntegrationCourse"
    field :id, GraphQL::Types::ID, null: false
    field :title, GraphQL::Types::String
    field :published, GraphQL::Types::Boolean
    field :author, author_type
    field :enrollments, [enrollment_type], null: false
  end

  course_filter = Class.new(GraphqlDeclarative::FilterInput) do
    graphql_name "IntegrationCourseFilter"
    filter :title, :string, ops: [:eq, :contains]
    filter :published, :boolean
    filter :author_name, :string, through: :author, column: :name, ops: [:eq]
    filter :enrollment_status, :string, through: :enrollments, column: :status, ops: [:eq]
  end

  courses_resolver = Class.new(GraphqlDeclarative::Resolver) do
    graphql_name "IntegrationCoursesResolver"
    type course_type.connection_type, null: false

    filterable_by course_filter
    sortable_by :title, :created_at
    paginate default_page_size: 2, max_page_size: 5
    preload_from_selection

    def base_scope
      Course.all
    end
  end

  query_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "IntegrationQuery"
    field :courses, resolver: courses_resolver
  end

  schema = Class.new(GraphQL::Schema) do
    query query_type
  end

  const_set(:SCHEMA, schema)

  def execute(query_string, variables: {})
    result = self.class.const_get(:SCHEMA).execute(query_string, variables: variables)
    raise result["errors"].inspect if result["errors"]
    result
  end

  def seed(count)
    count.times.map do |i|
      author = Author.create!(name: "Author #{i}")
      course = Course.create!(title: format("Course %02d", i), published: i.even?, author: author)
      2.times { |j| course.enrollments.create!(status: j.zero? ? "active" : "cancelled") }
      course
    end
  end

  # -------------------------------------------------------------------------

  let(:full_query) do
    <<~GQL
      query($first: Int) {
        courses(first: $first, sortBy: TITLE, sortDirection: ASC) {
          pageInfo { hasNextPage hasPreviousPage }
          edges {
            cursor
            node {
              id
              title
              author { name }
              enrollments { status }
            }
          }
        }
      }
    GQL
  end

  it "returns the right data" do
    seed(3)
    result = execute(full_query, variables: {"first" => 2})
    nodes = result.dig("data", "courses", "edges").map { |edge| edge["node"] }

    expect(nodes.map { |n| n["title"] }).to eq(["Course 00", "Course 01"])
    expect(nodes.first["author"]["name"]).to eq("Author 0")
    expect(nodes.first["enrollments"].map { |e| e["status"] }).to contain_exactly("active", "cancelled")
    expect(result.dig("data", "courses", "pageInfo", "hasNextPage")).to be(true)
  end

  it "costs exactly 3 queries: the page, the authors, the enrollments" do
    seed(3)
    statements = count_queries { execute(full_query, variables: {"first" => 2}) }

    expect(statements.size).to eq(3)
    expect(statements[0]).to match(/FROM "courses"/)
    expect(statements.join("\n")).to match(/FROM "authors"/)
    expect(statements.join("\n")).to match(/FROM "enrollments"/)
  end

  it "costs the SAME 3 queries with ten times the data — this is the N+1 proof" do
    seed(30)
    statements = count_queries { execute(full_query, variables: {"first" => 5}) }

    expect(statements.size).to eq(3)
  end

  it "issues no COUNT — has_next_page comes from the +1 row" do
    seed(10)
    statements = count_queries { execute(full_query, variables: {"first" => 2}) }

    expect(statements.join("\n")).not_to match(/COUNT\(/i)
  end

  it "costs 1 query when the selection asks for no associations" do
    seed(10)
    query = "{ courses(first: 3) { edges { node { title } } } }"

    statements = count_queries { execute(query) }

    expect(statements.size).to eq(1)
  end

  it "adds no query for an association filter — the subquery is inline" do
    seed(5)
    query = <<~GQL
      {
        courses(first: 3, filter: {enrollmentStatus: "active"}) {
          edges { node { title } }
        }
      }
    GQL

    statements = count_queries { execute(query) }

    expect(statements.size).to eq(1)
    expect(statements.first).to match(/IN \(SELECT/)
  end

  describe "the declared behaviour end to end" do
    before { seed(6) }

    it "filters on a direct column" do
      result = execute("{ courses(first: 10, filter: {published: true}) { edges { node { title } } } }")

      expect(result.dig("data", "courses", "edges").size).to eq(3)
    end

    it "filters through an association without corrupting the page size" do
      # Every course has one active enrollment; a joins-based filter would give
      # each course two rows and a `first: 5` page would hold fewer than 5.
      result = execute(<<~GQL)
        { courses(first: 5, filter: {enrollmentStatus: "active"}) { edges { node { title } } } }
      GQL

      titles = result.dig("data", "courses", "edges").map { |e| e.dig("node", "title") }
      expect(titles.size).to eq(5)
      expect(titles.uniq.size).to eq(5)
    end

    it "sorts descending when asked" do
      result = execute("{ courses(first: 2, sortBy: TITLE, sortDirection: DESC) { edges { node { title } } } }")

      expect(result.dig("data", "courses", "edges").map { |e| e.dig("node", "title") })
        .to eq(["Course 05", "Course 04"])
    end

    it "clamps first: above max_page_size instead of erroring" do
      result = execute("{ courses(first: 500) { edges { node { title } } } }")

      expect(result.dig("data", "courses", "edges").size).to eq(5)
    end

    it "uses default_page_size when first: is omitted" do
      result = execute("{ courses { edges { node { title } } } }")

      expect(result.dig("data", "courses", "edges").size).to eq(2)
    end

    it "walks pages with the cursors it issued" do
      page1 = execute("{ courses(first: 2, sortBy: TITLE) { edges { cursor node { title } } } }")
      cursor = page1.dig("data", "courses", "edges").last["cursor"]

      page2 = execute(<<~GQL, variables: {"after" => cursor})
        query($after: String) {
          courses(first: 2, after: $after, sortBy: TITLE) { edges { node { title } } }
        }
      GQL

      expect(page2.dig("data", "courses", "edges").map { |e| e.dig("node", "title") })
        .to eq(["Course 02", "Course 03"])
    end

    it "reports hasPreviousPage as false — forward-only, and it says so" do
      result = execute("{ courses(first: 2) { pageInfo { hasPreviousPage } } }")

      expect(result.dig("data", "courses", "pageInfo", "hasPreviousPage")).to be(false)
    end
  end

  describe "client errors surface as GraphQL errors, not 500s" do
    before { seed(2) }

    it "for a malformed cursor" do
      # Valid Base64, but the payload is not a cursor. It must be an error, not
      # a silent reset to page 1 (SPEC.md 6.4).
      junk = Base64.urlsafe_encode64("not-a-cursor", padding: false)
      result = self.class.const_get(:SCHEMA).execute(
        "{ courses(first: 2, after: \"#{junk}\") { edges { node { title } } } }"
      )

      expect(result["errors"].first["message"]).to match(/cursor/i)
    end

    it "for a cursor that is not even Base64" do
      result = self.class.const_get(:SCHEMA).execute(
        "{ courses(first: 2, after: \"!!!!\") { edges { node { title } } } }"
      )

      # .scrub because the decoder echoes the offending bytes into the message;
      # they are not necessarily valid UTF-8.
      expect(result["errors"]).not_to be_empty
      expect(result["errors"].first["message"].to_s.scrub).to match(/cursor/i)
    end

    it "for an unknown filter argument, at validation time" do
      result = self.class.const_get(:SCHEMA).execute(
        '{ courses(filter: {nonexistent: "x"}) { edges { node { title } } } }'
      )

      expect(result["errors"]).not_to be_empty
    end

    it "for an unsortable field, at validation time" do
      result = self.class.const_get(:SCHEMA).execute(
        "{ courses(sortBy: PUBLISHED) { edges { node { title } } } }"
      )

      expect(result["errors"]).not_to be_empty
    end
  end

  describe "base_scope" do
    it "raises when it does not return a relation" do
      bad = Class.new(GraphqlDeclarative::Resolver) do
        graphql_name "IntegrationBadResolver"
        type GraphQL::Types::String.connection_type, null: false
        paginate

        def base_scope
          [1, 2, 3]
        end
      end

      bad_query = Class.new(GraphQL::Schema::Object) do
        graphql_name "IntegrationBadQuery"
        field :things, resolver: bad
      end

      bad_schema = Class.new(GraphQL::Schema) { query bad_query }

      expect { bad_schema.execute("{ things { edges { node } } }") }
        .to raise_error(GraphqlDeclarative::Error, /must return an ActiveRecord::Relation/)
    end
  end
end
