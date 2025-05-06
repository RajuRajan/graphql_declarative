# frozen_string_literal: true

# ---------------------------------------------------------------------------
# FilterInput turns declarations into GraphQL arguments (SPEC.md §4, §6.1).
#
# What matters here is that the *declaration* is the single source of truth:
# the generated argument names, the ops allowed per type, and the registry
# (`definitions`) that Filter later reads column and association identifiers
# back out of. Nothing in the SQL layer may come from anywhere else, so if this
# registry is wrong or incomplete the security property in SPEC.md §7 is gone.
#
# Configuration mistakes must blow up at class-definition time, not per request.
# ---------------------------------------------------------------------------

RSpec.describe GraphqlDeclarative::FilterInput do
  # Argument names are camelized by graphql-ruby; the keyword is the snake_case
  # symbol Filter matches against its argument index.
  def keywords(klass)
    klass.arguments.values.map(&:keyword).sort
  end

  def argument(klass, keyword)
    klass.arguments.values.find { |a| a.keyword == keyword }
  end

  describe "argument generation per op" do
    let(:filter_class) do
      Class.new(described_class) do
        graphql_name "ArgGenFilter"
        filter :title, :string, ops: [:eq, :contains, :starts_with, :ends_with, :in]
        filter :created_at, :datetime, ops: [:gte, :lte]
        filter :seats, :integer, ops: [:gt, :lt]
      end
    end

    it "names the :eq argument after the filter itself, never title_eq" do
      expect(keywords(filter_class)).to include(:title)
      expect(keywords(filter_class)).not_to include(:title_eq)
    end

    it "suffixes every other op with the op name" do
      expect(keywords(filter_class)).to eq(
        %i[created_at_gte created_at_lte seats_gt seats_lt title title_contains title_ends_with title_in title_starts_with].sort
      )
    end

    it "types the LIKE ops as String even when the column is not" do
      expect(argument(filter_class, :title_contains).type.unwrap).to eq(GraphQL::Types::String)
    end

    it "types :in as a list of the scalar" do
      type = argument(filter_class, :title_in).type
      expect(type.list?).to be(true)
      expect(type.unwrap).to eq(GraphQL::Types::String)
    end

    it "maps datetime to ISO8601DateTime" do
      expect(argument(filter_class, :created_at_gte).type.unwrap).to eq(GraphQL::Types::ISO8601DateTime)
    end

    it "makes every generated argument optional" do
      expect(filter_class.arguments.values.map(&:type).map(&:non_null?)).to all(be(false))
    end
  end

  describe "default ops" do
    it "gives a boolean :eq only — there is no `published_gt`" do
      klass = Class.new(described_class) do
        graphql_name "BoolDefaultFilter"
        filter :published, :boolean
      end

      expect(keywords(klass)).to eq([:published])
      expect(klass.definitions[:published].ops).to eq([:eq])
    end

    it "gives a string the full text set" do
      klass = Class.new(described_class) do
        graphql_name "StringDefaultFilter"
        filter :title, :string
      end

      expect(klass.definitions[:title].ops).to eq(described_class::DEFAULT_OPS[:string])
      expect(keywords(klass)).to eq(%i[title title_contains title_ends_with title_in title_starts_with].sort)
    end

    it "gives numeric types comparison ops" do
      klass = Class.new(described_class) do
        graphql_name "NumericDefaultFilter"
        filter :seats, :integer
        filter :price, :float
      end

      expect(klass.definitions[:seats].ops).to eq(%i[eq gt gte lt lte in])
      expect(klass.definitions[:price].ops).to eq(%i[eq gt gte lt lte])
    end
  end

  describe "definitions registry" do
    let(:filter_class) do
      Class.new(described_class) do
        graphql_name "RegistryFilter"
        filter :title, :string, ops: [:eq]
        filter :author_name, :string, through: :author, column: :name
        filter :status, :string, through: :enrollments, ops: [:eq]
      end
    end

    it "records the association and column for a through: filter" do
      definition = filter_class.definitions[:author_name]

      expect(definition.through).to eq(:author)
      expect(definition.column).to eq(:name)
    end

    it "defaults column: to the filter name" do
      expect(filter_class.definitions[:status].column).to eq(:status)
    end

    it "leaves through: nil for a direct filter" do
      expect(filter_class.definitions[:title].through).to be_nil
    end

    it "keys the registry by symbol" do
      expect(filter_class.definitions.keys).to eq(%i[title author_name status])
    end
  end

  describe "inheritance" do
    let(:parent) do
      Class.new(described_class) do
        graphql_name "ParentFilter"
        filter :title, :string, ops: [:eq]
      end
    end

    let(:child) do
      Class.new(parent) do
        graphql_name "ChildFilter"
        filter :published, :boolean
      end
    end

    it "lets a subclass see its parent's definitions" do
      expect(child.definitions.keys).to contain_exactly(:title, :published)
    end

    it "does not leak the subclass's definitions back into the parent" do
      child # force definition
      expect(parent.definitions.keys).to eq([:title])
    end

    it "inherits the parent's generated arguments too" do
      expect(keywords(child)).to eq(%i[published title])
    end

    it "picks up a filter added to the parent after the subclass was defined" do
      child # force definition
      parent.filter :seats, :integer, ops: [:eq]

      expect(child.definitions.keys).to include(:seats)
    end
  end

  describe "config-time errors" do
    it "raises for an unknown type" do
      expect {
        Class.new(described_class) do
          graphql_name "UnknownTypeFilter"
          filter :title, :uuid
        end
      }.to raise_error(GraphqlDeclarative::Error, /unknown filter type :uuid/)
    end

    it "raises for an op that is not valid for the type" do
      expect {
        Class.new(described_class) do
          graphql_name "BadOpFilter"
          filter :published, :boolean, ops: [:contains]
        end
      }.to raise_error(GraphqlDeclarative::Error, /invalid op\(s\) \[:contains\]/)
    end

    it "raises for an empty ops list" do
      expect {
        Class.new(described_class) do
          graphql_name "EmptyOpsFilter"
          filter :title, :string, ops: []
        end
      }.to raise_error(GraphqlDeclarative::Error, /empty ops list/)
    end

    it "raises at class-definition time, not on first use" do
      # The point of the previous three: the exception is raised while the class
      # body runs, so a bad declaration is a boot failure and can never reach a
      # request.
      raised = nil
      begin
        Class.new(described_class) do
          graphql_name "BootFailFilter"
          filter :title, :string, ops: [:gte]
        end
      rescue GraphqlDeclarative::Error => e
        raised = e
      end

      expect(raised).to be_a(GraphqlDeclarative::Error)
    end
  end

  describe ".argument_name_for" do
    it "is the naming table from SPEC.md §4" do
      expect(described_class.argument_name_for(:title, :eq)).to eq(:title)
      expect(described_class.argument_name_for(:title, :contains)).to eq(:title_contains)
      expect(described_class.argument_name_for(:created_at, :gte)).to eq(:created_at_gte)
    end
  end
end
