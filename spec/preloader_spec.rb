# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Preloader.from_lookahead (SPEC.md §6.6).
#
# The preload set is derived from the query's actual selection set, so it cannot
# drift from what the query asks for. A hand-kept `.includes(...)` list is a
# second source of truth, and the day someone adds a field without updating it
# is the day an N+1 ships.
#
# Three details do the work:
#   * connection plumbing (edges / node / nodes) is UNWRAPPED before names are
#     matched against associations — otherwise every connection field looks like
#     a leaf and nothing is ever preloaded;
#   * a selection becomes a preload only if it is a real association; plain
#     columns are ignored;
#   * recursion is depth-capped, so a client cannot dictate the size of the
#     preload tree by nesting a cheap-to-write query.
#
# The lookahead is taken from a real executed query rather than stubbed: the
# shape graphql-ruby actually hands a resolver is the thing under test.
# ---------------------------------------------------------------------------

RSpec.describe GraphqlDeclarative::Preloader do
  # --- a real schema, so `lookahead` is the real object --------------------

  captured = nil

  enrollment_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "PreloaderEnrollment"
    field :id, GraphQL::Types::ID, null: false
    field :status, GraphQL::Types::String
  end

  author_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "PreloaderAuthor"
    field :id, GraphQL::Types::ID, null: false
    field :name, GraphQL::Types::String
  end

  course_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "PreloaderCourse"
    field :id, GraphQL::Types::ID, null: false
    field :title, GraphQL::Types::String
    field :published, GraphQL::Types::Boolean
    field :author, author_type
    field :enrollments, [enrollment_type]
  end

  # Author -> courses -> enrollments gives four association levels to test the
  # depth cap against.
  author_type.field :courses, [course_type]
  enrollment_type.field :course, course_type

  query_type = Class.new(GraphQL::Schema::Object) do
    graphql_name "PreloaderQuery"

    field :courses, course_type.connection_type, null: false, extras: [:lookahead]
    field :course_list, [course_type], null: false, extras: [:lookahead]

    define_method(:courses) do |lookahead:|
      captured = lookahead
      Course.all.to_a
    end

    define_method(:course_list) do |lookahead:|
      captured = lookahead
      Course.all.to_a
    end
  end

  schema = Class.new(GraphQL::Schema) do
    query query_type
  end

  # Yields the lookahead graphql-ruby built for the `courses` field.
  def lookahead_for(query_string)
    result = self.class.const_get(:SCHEMA).execute(query_string)
    raise result["errors"].inspect if result["errors"]
    self.class.const_get(:CAPTOR).call
  end

  const_set(:SCHEMA, schema)
  const_set(:CAPTOR, -> { captured })

  before { captured = nil }

  describe "selection-set walk" do
    it "preloads an association the query selects" do
      lookahead = lookahead_for("{ courses { edges { node { author { name } } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq(author: [])
    end

    it "preloads several associations at one level" do
      lookahead = lookahead_for("{ courses { edges { node { author { name } enrollments { status } } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq(author: [], enrollments: [])
    end

    it "recurses to build a nested hash" do
      lookahead = lookahead_for("{ courses { edges { node { enrollments { course { title } } } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq(enrollments: [:course])
    end

    it "unions the same association selected twice under different aliases" do
      lookahead = lookahead_for(<<~GQL)
        {
          courses {
            edges {
              node {
                a: enrollments { status }
                b: enrollments { course { title } }
              }
            }
          }
        }
      GQL

      expect(described_class.from_lookahead(lookahead, Course)).to eq(enrollments: [:course])
    end

    it "returns an empty hash when nothing associated is selected" do
      lookahead = lookahead_for("{ courses { edges { node { title } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq({})
    end
  end

  describe "connection unwrapping" do
    it "descends through edges -> node" do
      lookahead = lookahead_for("{ courses { edges { node { author { name } } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq(author: [])
    end

    it "descends through nodes" do
      lookahead = lookahead_for("{ courses { nodes { author { name } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq(author: [])
    end

    it "works on a plain list field with no connection wrapper at all" do
      lookahead = lookahead_for("{ courseList { author { name } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq(author: [])
    end

    it "does not treat `edges` or `node` as associations in their own right" do
      lookahead = lookahead_for("{ courses { edges { cursor node { title } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq({})
    end
  end

  describe "columns and plumbing are ignored" do
    it "ignores plain columns" do
      lookahead = lookahead_for("{ courses { edges { node { id title published } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq({})
    end

    it "ignores pageInfo and cursor" do
      lookahead = lookahead_for("{ courses { pageInfo { hasNextPage } edges { cursor node { title } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq({})
    end

    it "ignores __typename" do
      lookahead = lookahead_for("{ courses { edges { node { __typename title } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq({})
    end

    it "keeps the associations and drops the columns from a mixed selection" do
      lookahead = lookahead_for("{ courses { edges { node { title author { id name } } } } }")

      expect(described_class.from_lookahead(lookahead, Course)).to eq(author: [])
    end
  end

  describe "depth cap" do
    let(:deep) do
      lookahead_for(<<~GQL)
        {
          courses {
            edges {
              node {
                enrollments {
                  course {
                    author {
                      courses { title }
                    }
                  }
                }
              }
            }
          }
        }
      GQL
    end

    it "descends at most max_depth association levels by default" do
      # enrollments (1) -> course (2) -> author (3); `courses` under author is
      # the fourth hop and is not preloaded. It still resolves, just lazily.
      expect(described_class.from_lookahead(deep, Course))
        .to eq(enrollments: [{course: [:author]}])
    end

    it "honours an explicit smaller cap" do
      expect(described_class.from_lookahead(deep, Course, max_depth: 1)).to eq(enrollments: [])
    end

    it "returns nothing at all at depth 0" do
      expect(described_class.from_lookahead(deep, Course, max_depth: 0)).to eq({})
    end

    it "descends further when the cap is raised" do
      expect(described_class.from_lookahead(deep, Course, max_depth: 4))
        .to eq(enrollments: [{course: [{author: [:courses]}]}])
    end

    it "does not spend depth budget on connection wrappers" do
      # edges/node are structural. If unwrapping consumed budget, this two-hop
      # query would come back as a one-hop preload.
      lookahead = lookahead_for("{ courses { edges { node { enrollments { course { title } } } } } }")

      expect(described_class.from_lookahead(lookahead, Course, max_depth: 2)).to eq(enrollments: [:course])
    end
  end

  describe "merging with static declarations" do
    it "adds the static preloads to the derived ones" do
      lookahead = lookahead_for("{ courses { edges { node { enrollments { status } } } } }")

      expect(described_class.from_lookahead(lookahead, Course, static: :author))
        .to eq(author: [], enrollments: [])
    end

    it "does not let the derived tree flatten a deeper static declaration" do
      lookahead = lookahead_for("{ courses { edges { node { enrollments { status } } } } }")

      result = described_class.from_lookahead(lookahead, Course, static: {enrollments: :course})

      expect(result).to eq(enrollments: [:course])
    end

    it "keeps both branches when static and derived overlap partially" do
      lookahead = lookahead_for("{ courses { edges { node { enrollments { course { title } } } } } }")

      result = described_class.from_lookahead(lookahead, Course, static: {author: []})

      expect(result).to eq(author: [], enrollments: [:course])
    end

    describe ".merge" do
      it "accepts a symbol, an array or a hash on either side" do
        expect(described_class.merge(:author, {})).to eq(author: [])
        expect(described_class.merge([:author, :enrollments], {})).to eq(author: [], enrollments: [])
        expect(described_class.merge({author: :profile}, {})).to eq(author: [:profile])
      end

      it "unions nested trees rather than letting one side win" do
        expect(described_class.merge({author: :profile}, {author: {courses: {enrollments: {}}}}))
          .to eq(author: [:profile, {courses: [:enrollments]}])
      end

      it "treats nil as no declaration" do
        expect(described_class.merge(nil, nil)).to eq({})
      end

      it "raises on something it cannot interpret" do
        expect { described_class.merge(42, nil) }
          .to raise_error(GraphqlDeclarative::Error, /cannot interpret/)
      end
    end
  end

  describe "the result is usable" do
    it "is accepted by ActiveRecord::Relation#preload" do
      author = Author.create!(name: "Matheson")
      course = Course.create!(title: "Ruby", author: author)
      course.enrollments.create!(status: "active")

      lookahead = lookahead_for("{ courses { edges { node { author { name } enrollments { status } } } } }")
      associations = described_class.from_lookahead(lookahead, Course)

      loaded = Course.preload(associations).to_a

      expect(loaded.first.association(:author)).to be_loaded
      expect(loaded.first.association(:enrollments)).to be_loaded
    end
  end
end
