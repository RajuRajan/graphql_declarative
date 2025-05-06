# frozen_string_literal: true

module GraphqlDeclarative
  # A GraphQL::Schema::InputObject built from `filter` declarations.
  #
  #   class Types::CourseFilter < GraphqlDeclarative::FilterInput
  #     filter :title,       :string,   ops: [:eq, :contains, :starts_with]
  #     filter :published,   :boolean
  #     filter :created_at,  :datetime, ops: [:gte, :lte]
  #     filter :author_name, :string,   through: :author, column: :name
  #   end
  #
  # Each (name, op) pair generates one argument: :title_contains, :created_at_gte.
  # `:eq` generates the bare name (:title), not :title_eq.
  #
  # The registry (`definitions`) is what `Filter.apply` reads back at request
  # time. It is the ONLY source of column and association identifiers — nothing
  # in the SQL layer is ever derived from user input. See SPEC.md section 7.
  class FilterInput < GraphQL::Schema::InputObject
    DEFAULT_OPS = {
      string: %i[eq contains starts_with ends_with in],
      integer: %i[eq gt gte lt lte in],
      float: %i[eq gt gte lt lte],
      boolean: %i[eq],
      datetime: %i[eq gt gte lt lte]
    }.freeze

    # The GraphQL scalar each declared type maps to. `:in` wraps this in a list
    # and the LIKE ops (contains/starts_with/ends_with) override it to String.
    GRAPHQL_TYPES = {
      string: GraphQL::Types::String,
      integer: GraphQL::Types::Int,
      float: GraphQL::Types::Float,
      boolean: GraphQL::Types::Boolean,
      datetime: GraphQL::Types::ISO8601DateTime
    }.freeze

    Definition = Struct.new(:name, :type, :ops, :through, :column, keyword_init: true)

    class << self
      # Declare one filterable attribute and generate one argument per op.
      #
      # Everything here fails loudly at class-definition time (SPEC.md 6.1):
      # an unknown type or an op that makes no sense for the type is a boot
      # error, never a per-request surprise.
      def filter(name, type, ops: nil, through: nil, column: nil)
        name = name.to_sym
        type = type.to_sym

        valid_ops = DEFAULT_OPS[type]
        unless valid_ops
          raise Error, "unknown filter type #{type.inspect} for filter #{name.inspect}; " \
                       "expected one of #{DEFAULT_OPS.keys.inspect}"
        end

        ops = Array(ops || valid_ops).map(&:to_sym)
        raise Error, "filter #{name.inspect} declares an empty ops list" if ops.empty?

        invalid = ops - valid_ops
        unless invalid.empty?
          raise Error, "invalid op(s) #{invalid.inspect} for #{type} filter #{name.inspect}; " \
                       "valid ops for #{type} are #{valid_ops.inspect}"
        end

        definition = Definition.new(
          name: name,
          type: type,
          ops: ops.freeze,
          through: through&.to_sym,
          # `column:` defaults to the filter name; for a `through:` filter it is
          # the column on the ASSOCIATION's table, not on the base model.
          column: (column || name).to_sym
        )

        own_definitions[name] = definition

        ops.each do |op|
          argument(argument_name_for(name, op), graphql_type_for(type, op), required: false)
        end

        definition
      end

      # {Symbol => Definition}. Inheritance-safe: walking `superclass` on every
      # read means a subclass sees its parent's declarations without ever
      # holding (or mutating) the parent's hash. Adding a filter to the parent
      # after the subclass exists is picked up too.
      def definitions
        if superclass.respond_to?(:definitions)
          superclass.definitions.merge(own_definitions)
        else
          own_definitions.dup
        end
      end

      # Declarations made directly on this class, excluding inherited ones.
      def own_definitions
        @own_definitions ||= {}
      end

      # The argument naming table from SPEC.md section 4. `:eq` is the bare
      # name — `title`, never `title_eq`.
      def argument_name_for(name, op)
        (op.to_sym == :eq) ? name.to_sym : :"#{name}_#{op}"
      end

      private

      def graphql_type_for(type, op)
        base =
          case op
          when :contains, :starts_with, :ends_with then GraphQL::Types::String
          else GRAPHQL_TYPES.fetch(type)
          end

        (op == :in) ? [base] : base
      end
    end
  end
end
