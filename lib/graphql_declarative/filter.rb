# frozen_string_literal: true

module GraphqlDeclarative
  # Applies a FilterInput's arguments to an ActiveRecord scope.
  #
  # THE IMPORTANT PART — see spec/pagination_through_associations_spec.rb.
  # Filters declared with `through:` MUST NOT be applied as a join on the scope
  # being paginated. Resolve them to an id subquery instead:
  #
  #   ids = model.joins(through).where(assoc_table => {column => value}).select(:id)
  #   scope.where(id: ids)
  #
  # The base relation then stays un-joined, so LIMIT, ORDER BY and cursors all
  # remain correct. Two `through:` filters on the same association must
  # intersect within ONE subquery, not chain two (that changes the meaning from
  # "one child matching both" to "children matching each").
  #
  # Chosen semantic, stated once so it is not rediscovered by accident:
  # ONE CHILD ROW MUST SATISFY ALL PREDICATES DECLARED FOR THAT ASSOCIATION.
  class Filter
    # Ops that compare with a LIKE pattern. The pattern is built here, from a
    # sanitized value, and passed as a bound/quoted node — never spliced into
    # SQL text.
    LIKE_PATTERNS = {
      contains: ->(v) { "%#{v}%" },
      starts_with: ->(v) { "#{v}%" },
      ends_with: ->(v) { "%#{v}" }
    }.freeze

    # LIKE's own metacharacters are escaped so a user-supplied "100%" means the
    # literal string, not "100 followed by anything". `ESCAPE '\'` is emitted
    # explicitly because only MySQL assumes backslash by default.
    LIKE_ESCAPE = "\\"

    class << self
      # scope        - ActiveRecord::Relation (or a model class)
      # filter_class - a GraphqlDeclarative::FilterInput subclass
      # args         - the `filter:` input, as a Hash with symbol keys, a
      #                GraphQL::Schema::InputObject, or nil
      def apply(scope, filter_class, args)
        args = normalize_args(args)
        relation = scope.respond_to?(:all) ? scope.all : scope
        return relation if args.empty?

        model = relation.klass
        index = argument_index(filter_class)

        direct = []
        # Keyed by association name so that every predicate on one association
        # ends up in the SAME subquery. This grouping IS the semantic.
        through = Hash.new { |h, k| h[k] = [] }

        args.each do |key, value|
          definition, op = index[key.to_sym]
          unless definition
            raise Error, "unknown filter argument #{key.inspect} for #{filter_class}; " \
                         "known arguments: #{index.keys.sort.inspect}"
          end
          # A key that was not supplied is absent from the hash; an explicit nil
          # is treated as "not filtering on this", not as `IS NULL`.
          next if value.nil?

          (definition.through ? through[definition.through] : direct) << [definition, op, value]
        end

        relation = apply_direct(relation, model, direct)
        apply_through(relation, model, through)
      end

      private

      def normalize_args(args)
        return {} if args.nil?
        return args if args.is_a?(Hash)
        return args.to_h if args.respond_to?(:to_h)

        raise Error, "filter args must be a Hash or nil, got #{args.class}"
      end

      # {argument_name => [Definition, op]} — the reverse of the naming table in
      # SPEC.md section 4. Built from `definitions` only, so every column and
      # association identifier below is declaration-derived.
      def argument_index(filter_class)
        unless filter_class.respond_to?(:definitions)
          raise Error, "#{filter_class} is not a GraphqlDeclarative::FilterInput"
        end

        filter_class.definitions.each_with_object({}) do |(name, definition), index|
          definition.ops.each do |op|
            index[FilterInput.argument_name_for(name, op)] = [definition, op]
          end
        end
      end

      def apply_direct(relation, model, entries)
        entries.reduce(relation) do |rel, (definition, op, value)|
          rel.where(predicate(model.arel_table, definition.column, op, value))
        end
      end

      # One subquery per association, never a join on `relation` itself.
      def apply_through(relation, model, grouped)
        grouped.reduce(relation) do |rel, (association, entries)|
          reflection = model.reflect_on_association(association)
          unless reflection
            raise Error, "#{model} has no association #{association.inspect} " \
                         "(declared as `through:` on filter #{entries.first[0].name.inspect})"
          end

          assoc_table = reflection.klass.arel_table

          # Build the subquery on the bare model. It may be joined freely: it
          # projects ids, so duplicate rows collapse inside `IN (...)` and never
          # reach the paginated relation.
          subquery = entries.reduce(model.joins(association)) do |sub, (definition, op, value)|
            sub.where(predicate(assoc_table, definition.column, op, value))
          end

          key = model.primary_key
          rel.where(key => subquery.select(model.arel_table[key]))
        end
      end

      # Column identifiers come from the Definition; values go through Arel's
      # quoted/typecast nodes. There is no string interpolation of SQL here.
      def predicate(table, column, op, value)
        attribute = table[column]

        case op
        when :eq then attribute.eq(value)
        when :in then attribute.in(Array(value))
        when :gt then attribute.gt(value)
        when :gte then attribute.gteq(value)
        when :lt then attribute.lt(value)
        when :lte then attribute.lteq(value)
        when :contains, :starts_with, :ends_with
          pattern = LIKE_PATTERNS.fetch(op).call(sanitize_like(value))
          # case_sensitive: true keeps this a plain LIKE on PostgreSQL too,
          # instead of Arel's default ILIKE.
          attribute.matches(pattern, Arel::Nodes.build_quoted(LIKE_ESCAPE), true)
        else
          raise Error, "unsupported filter op #{op.inspect}"
        end
      end

      def sanitize_like(value)
        ActiveRecord::Base.sanitize_sql_like(value.to_s, LIKE_ESCAPE)
      end
    end
  end
end
