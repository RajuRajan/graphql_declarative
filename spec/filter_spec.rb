# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Filter.apply (SPEC.md §6.2).
#
# Two things are being protected here.
#
# 1. Association filters must NEVER become a join on the relation being
#    paginated. They become `WHERE id IN (subquery)`. The reason is
#    spec/pagination_through_associations_spec.rb: a join multiplies rows and
#    LIMIT then returns fewer distinct records than it promised.
#
# 2. All predicates on ONE association go into ONE subquery. That is the
#    documented semantic: one child row must satisfy all of them. Chaining two
#    subqueries would instead mean "some child matches A and some child matches
#    B" — a different question, and not the one the caller asked.
# ---------------------------------------------------------------------------

RSpec.describe GraphqlDeclarative::Filter do
  let(:filter_class) do
    Class.new(GraphqlDeclarative::FilterInput) do
      graphql_name "SpecCourseFilter"
      filter :title, :string, ops: [:eq, :contains, :starts_with, :ends_with, :in]
      filter :published, :boolean
      filter :created_at, :datetime, ops: [:gte, :lte]
      filter :author_name, :string, through: :author, column: :name, ops: [:eq, :contains]
      filter :enrollment_status, :string, through: :enrollments, column: :status, ops: [:eq]
      filter :enrolled_after, :datetime, through: :enrollments, column: :created_at, ops: [:gte]
    end
  end

  def apply(args)
    described_class.apply(Course.all, filter_class, args)
  end

  describe "no-op cases" do
    it "returns the scope unchanged for nil args" do
      expect(apply(nil).to_sql).to eq(Course.all.to_sql)
    end

    it "returns the scope unchanged for an empty hash" do
      expect(apply({}).to_sql).to eq(Course.all.to_sql)
    end

    it "ignores an explicitly nil value rather than generating IS NULL" do
      expect(apply(title: nil).to_sql).not_to match(/IS NULL/)
    end
  end

  describe "direct predicates" do
    let!(:ruby) { Course.create!(title: "Ruby 101", published: true, created_at: Time.utc(2024, 1, 1)) }
    let!(:rails) { Course.create!(title: "Rails 101", published: false, created_at: Time.utc(2024, 6, 1)) }
    let!(:python) { Course.create!(title: "Python 101", published: true, created_at: Time.utc(2024, 12, 1)) }

    it "eq uses the bare argument name" do
      expect(apply(title: "Ruby 101").to_a).to eq([ruby])
    end

    it "contains" do
      expect(apply(title_contains: "101").to_a).to match_array([ruby, rails, python])
      expect(apply(title_contains: "uby").to_a).to eq([ruby])
    end

    it "starts_with" do
      expect(apply(title_starts_with: "Ra").to_a).to eq([rails])
    end

    it "ends_with" do
      expect(apply(title_ends_with: "101").to_a).to match_array([ruby, rails, python])
    end

    it "in" do
      expect(apply(title_in: ["Ruby 101", "Python 101"]).to_a).to match_array([ruby, python])
    end

    it "boolean eq" do
      expect(apply(published: false).to_a).to eq([rails])
    end

    it "gte / lte on a datetime" do
      expect(apply(created_at_gte: Time.utc(2024, 6, 1)).to_a).to match_array([rails, python])
      expect(apply(created_at_lte: Time.utc(2024, 6, 1)).to_a).to match_array([ruby, rails])
    end

    it "ANDs multiple direct filters" do
      expect(apply(published: true, title_contains: "101").to_a).to match_array([ruby, python])
    end

    it "escapes LIKE metacharacters so a literal % is not a wildcard" do
      Course.create!(title: "100% Ruby")
      literal = Course.create!(title: "50%off")

      expect(apply(title_contains: "%o").to_a).to eq([literal])
    end

    it "quotes the value rather than splicing it into the statement" do
      # The value is a bind/quoted node, so the injected statement terminator is
      # escaped and stays inside the string literal. Column identifiers, by
      # contrast, never come from input at all (SPEC.md §7) — they come from the
      # Definition, which is why there is no equivalent test for them: there is
      # no code path to test.
      relation = apply(title: "Robert'); DROP TABLE courses;--")

      expect(relation.to_sql).to include("'Robert''); DROP TABLE courses;--'")
      expect(relation.to_a).to eq([])
      expect(Course.count).to eq(3)
    end
  end

  describe "association filters" do
    let!(:matheson) { Author.create!(name: "Matheson") }
    let!(:other) { Author.create!(name: "Okorafor") }

    let!(:with_active) do
      course = Course.create!(title: "A", author: matheson)
      course.enrollments.create!(status: "active")
      course.enrollments.create!(status: "cancelled")
      course
    end

    let!(:only_cancelled) do
      course = Course.create!(title: "B", author: other)
      course.enrollments.create!(status: "cancelled")
      course
    end

    let!(:split) do
      course = Course.create!(title: "C", author: other)
      course.enrollments.create!(status: "active")
      course
    end

    it "filters through a belongs_to" do
      expect(apply(author_name: "Matheson").to_a).to eq([with_active])
    end

    it "filters through a has_many" do
      expect(apply(enrollment_status: "active").to_a).to match_array([with_active, split])
    end

    it "never joins the relation being paginated" do
      relation = apply(enrollment_status: "active")

      expect(relation.joins_values).to be_empty
      expect(relation.to_sql).not_to match(/\ASELECT[^(]*INNER JOIN/)
    end

    it "constrains the scope with an id subquery" do
      expect(apply(enrollment_status: "active").to_sql).to match(/"courses"\."id" IN \(SELECT/)
    end

    it "returns each matching record exactly once, despite duplicate children" do
      # with_active has one active enrollment, but the point stands for many:
      3.times { with_active.enrollments.create!(status: "active") }

      relation = apply(enrollment_status: "active")

      expect(relation.count).to eq(2)
      expect(relation.to_a.map(&:id).uniq.size).to eq(2)
    end

    it "leaves LIMIT meaning what it says" do
      3.times { with_active.enrollments.create!(status: "active") }

      page = apply(enrollment_status: "active").order(:id).limit(2).to_a

      expect(page.map(&:id)).to eq([with_active.id, split.id])
    end
  end

  describe "one subquery per association" do
    let(:cutoff) { Time.utc(2024, 6, 1) }

    let!(:both_on_one_row) do
      # ONE enrollment that is both active AND recent.
      course = Course.create!(title: "One row satisfies both")
      course.enrollments.create!(status: "active", created_at: Time.utc(2024, 9, 1))
      course
    end

    let!(:spread_over_two_rows) do
      # The discriminating fixture. This course HAS an active enrollment, and it
      # HAS a recent enrollment — but no single enrollment is both.
      course = Course.create!(title: "Two rows, neither satisfies both")
      course.enrollments.create!(status: "active", created_at: Time.utc(2024, 1, 1))
      course.enrollments.create!(status: "cancelled", created_at: Time.utc(2024, 9, 1))
      course
    end

    it "builds exactly ONE subquery for two filters on the same association" do
      sql = apply(enrollment_status: "active", enrolled_after_gte: cutoff).to_sql

      expect(sql.scan("IN (SELECT").size).to eq(1)
      expect(sql.scan('INNER JOIN "enrollments"').size).to eq(1)
    end

    it "intersects both predicates inside that single subquery" do
      # The chosen semantic (SPEC.md §6.2): ONE CHILD ROW must satisfy ALL
      # predicates declared for that association. Two chained subqueries would
      # instead mean "some child is active and some child is recent", which
      # would wrongly return `spread_over_two_rows`.
      result = apply(enrollment_status: "active", enrolled_after_gte: cutoff).to_a

      expect(result).to eq([both_on_one_row])
      expect(result).not_to include(spread_over_two_rows)
    end

    it "builds a separate subquery per distinct association" do
      author = Author.create!(name: "Matheson")
      both_on_one_row.update!(author: author)

      sql = apply(enrollment_status: "active", author_name: "Matheson").to_sql

      expect(sql.scan("IN (SELECT").size).to eq(2)
      expect(apply(enrollment_status: "active", author_name: "Matheson").to_a).to eq([both_on_one_row])
    end

    it "combines direct and association filters" do
      both_on_one_row.update!(published: true)
      spread_over_two_rows.update!(published: true)

      result = apply(published: true, enrollment_status: "active").to_a

      expect(result).to match_array([both_on_one_row, spread_over_two_rows])
    end
  end

  describe "programmer errors" do
    it "raises on an unknown filter key rather than ignoring it" do
      expect { apply(nonexistent: "x") }
        .to raise_error(GraphqlDeclarative::Error, /unknown filter argument :nonexistent/)
    end

    it "raises on an op that was not declared for that filter" do
      # :published is boolean, so `published_gt` was never generated.
      expect { apply(published_gt: true) }
        .to raise_error(GraphqlDeclarative::Error, /unknown filter argument/)
    end

    it "raises when a through: association does not exist on the model" do
      bad = Class.new(GraphqlDeclarative::FilterInput) do
        graphql_name "BadThroughFilter"
        filter :ghost, :string, through: :ghosts, ops: [:eq]
      end

      expect { described_class.apply(Course.all, bad, ghost: "x") }
        .to raise_error(GraphqlDeclarative::Error, /no association :ghosts/)
    end

    it "raises when given something that is not a FilterInput" do
      expect { described_class.apply(Course.all, String, title: "x") }
        .to raise_error(GraphqlDeclarative::Error, /not a GraphqlDeclarative::FilterInput/)
    end
  end

  describe "input shapes" do
    it "accepts a GraphQL::Schema::InputObject as well as a Hash" do
      Course.create!(title: "Ruby 101")
      input = filter_class.new({title: "Ruby 101"}, ruby_kwargs: {title: "Ruby 101"}, context: nil, defaults_used: Set.new)

      expect(described_class.apply(Course.all, filter_class, input).count).to eq(1)
    end

    it "accepts a model class as the scope, not only a relation" do
      Course.create!(title: "Ruby 101")

      expect(described_class.apply(Course, filter_class, title: "Ruby 101").count).to eq(1)
    end
  end
end
