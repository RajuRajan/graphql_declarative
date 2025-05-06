# frozen_string_literal: true

module GraphqlDeclarative
  # The public surface. A resolver declares; it does not define `resolve`.
  #
  #   class Resolvers::Courses < GraphqlDeclarative::Resolver
  #     type Types::Course.connection_type, null: false
  #
  #     filterable_by Types::CourseFilter
  #     sortable_by   :title, :created_at
  #     paginate      cursor: :id, default_page_size: 25, max_page_size: 100
  #
  #     preload author: :profile
  #     preload_from_selection
  #
  #     def base_scope
  #       Course.where(school_id: context[:school_id])
  #     end
  #   end
  #
  # `resolve` is provided: base_scope -> Filter -> Sort -> Preloader -> page.
  # Order matters. Filter before sort; preload last, after the page is bounded,
  # or you preload the whole table.
  class Resolver < GraphQL::Schema::Resolver
    # Defaults for `paginate`, matching SPEC.md 6.5/6.7.
    DEFAULT_PAGE_SIZE = 25
    MAX_PAGE_SIZE = 100

    # One shared enum class, not one per resolver: it is the same two values
    # everywhere, and reusing the class means one `SortDirection` type in the
    # schema instead of one per list endpoint.
    class SortDirection < GraphQL::Schema::Enum
      graphql_name "SortDirection"
      description "Ordering direction for a sorted list."

      value "ASC", "Ascending order.", value: :asc
      value "DESC", "Descending order.", value: :desc
    end

    class << self
      # --- declarations ---------------------------------------------------
      #
      # Every reader below walks `superclass` instead of copying state into the
      # subclass at `inherited` time. Same rule as FilterInput (SPEC.md 6.1):
      # a subclass sees its parent's declarations, never holds the parent's
      # objects, and cannot mutate them by accident.

      # Adds the `filter:` argument of the given input type. The class itself is
      # remembered because `Filter.apply` reads `definitions` back off it at
      # request time — that registry is the only source of column and
      # association identifiers in the SQL layer (SPEC.md 7).
      def filterable_by(filter_class)
        unless filter_class.is_a?(Class) && filter_class < GraphQL::Schema::InputObject
          raise Error,
            "filterable_by expects a GraphqlDeclarative::FilterInput subclass, got #{filter_class.inspect}"
        end

        @own_filter_class = filter_class
        argument :filter, filter_class, required: false
        filter_class
      end

      # @return [Class, nil] the declared filter input, inherited if the
      #   subclass did not declare its own.
      def filter_class
        own = defined?(@own_filter_class) ? @own_filter_class : nil
        return own if own

        superclass.respond_to?(:filter_class) ? superclass.filter_class : nil
      end

      # Adds `sort_by:` (an enum of exactly these fields) and `sort_direction:`.
      #
      # The whitelist is the whole point: `sort_by` reaches ActiveRecord only
      # after Sort has matched it against this list and swapped in the list's
      # own canonical name. A column name never travels from the client into
      # SQL (SPEC.md 7).
      def sortable_by(*fields)
        fields = fields.flatten.compact.map(&:to_sym)
        raise Error, "sortable_by requires at least one field" if fields.empty?

        # Union with the inherited list rather than replacing it: a subclass
        # that adds one sortable field should not silently drop its parent's.
        fields = (inherited_sortable_fields + fields).uniq
        @own_sortable_fields = fields.freeze

        argument :sort_by, build_sort_by_enum(fields), required: false
        argument :sort_direction, SortDirection, required: false, default_value: :asc
        fields
      end

      # @return [Array<Symbol>] the sortable whitelist, empty when undeclared.
      #   Empty means "sort by :id ascending" (SPEC.md 6.7); Sort treats :id as
      #   implicitly sortable, so an empty whitelist is not a broken resolver.
      def sortable_fields
        own = defined?(@own_sortable_fields) ? @own_sortable_fields : nil
        return own if own

        inherited_sortable_fields
      end

      # Adds `first:` and `after:`, and records the page-size policy.
      #
      # `default_page_size`/`max_page_size` are set through graphql-ruby's own
      # resolver DSL so the field reports them in introspection too; the
      # connection reads them back from there.
      #
      # `cursor:` is optional and names the column to sort (and therefore issue
      # cursors) by when no `sortable_by` is declared. SPEC.md 6.7 lists
      # `paginate(default_page_size:, max_page_size:)`; `cursor:` is accepted
      # because the documented example in this file's header passes it.
      def paginate(cursor: nil, default_page_size: DEFAULT_PAGE_SIZE, max_page_size: MAX_PAGE_SIZE)
        @own_paginate = true
        @own_cursor_column = cursor&.to_sym

        self.default_page_size(Integer(default_page_size))
        self.max_page_size(Integer(max_page_size))

        argument :first, GraphQL::Types::Int, required: false
        argument :after, GraphQL::Types::String, required: false
        true
      end

      # @return [Boolean] whether `paginate` was declared here or by an ancestor.
      def paginate?
        return true if defined?(@own_paginate) && @own_paginate

        superclass.respond_to?(:paginate?) ? superclass.paginate? : false
      end

      # @return [Symbol, nil] the `paginate cursor:` column, if one was given.
      def cursor_column
        own = defined?(@own_cursor_column) ? @own_cursor_column : nil
        return own if own

        superclass.respond_to?(:cursor_column) ? superclass.cursor_column : nil
      end

      # Preloads that are applied on every request regardless of the query.
      # Accepts anything `.preload` accepts: `:author`, `[:a, :b]`,
      # `{author: :profile}`.
      def preload(*args)
        own_static_preloads.concat(args)
        own_static_preloads
      end

      # @return [Array] declared preloads, ancestors first.
      def static_preloads
        inherited = superclass.respond_to?(:static_preloads) ? superclass.static_preloads : []
        inherited + own_static_preloads
      end

      def own_static_preloads
        @own_static_preloads ||= []
      end

      # Derive the rest of the preload set from what the query actually selects,
      # so adding a field to a query cannot reintroduce an N+1 and no hand-kept
      # `.includes` list can drift.
      #
      # This needs the lookahead, which graphql-ruby only passes when the field
      # asks for it, hence the `extras` registration.
      def preload_from_selection(max_depth: Preloader::DEFAULT_MAX_DEPTH)
        @own_preload_from_selection = true
        @own_preload_max_depth = Integer(max_depth)

        current = extras
        extras(current + [:lookahead]) unless current.include?(:lookahead)
        true
      end

      def preload_from_selection?
        return true if defined?(@own_preload_from_selection) && @own_preload_from_selection

        superclass.respond_to?(:preload_from_selection?) ? superclass.preload_from_selection? : false
      end

      def preload_max_depth
        own = defined?(@own_preload_max_depth) ? @own_preload_max_depth : nil
        return own if own

        if superclass.respond_to?(:preload_max_depth)
          superclass.preload_max_depth
        else
          Preloader::DEFAULT_MAX_DEPTH
        end
      end

      private

      def inherited_sortable_fields
        superclass.respond_to?(:sortable_fields) ? superclass.sortable_fields : []
      end

      # One enum per resolver, named after it. Enum *values* are the whitelisted
      # symbols themselves, so `args[:sort_by]` arrives as `:created_at` — the
      # declaration's own symbol, never a client string.
      def build_sort_by_enum(fields)
        prefix = graphql_name_prefix

        Class.new(GraphQL::Schema::Enum) do
          graphql_name "#{prefix}SortBy"
          description "Fields #{prefix} can be sorted by."

          fields.each { |field_name| value(field_name.to_s.upcase, value: field_name) }
        end
      end

      # GraphQL type names must be unique and must match /[_A-Za-z][_0-9A-Za-z]*/.
      # Anonymous resolver classes (common in specs) get a stable synthetic name.
      def graphql_name_prefix
        base = name.to_s.gsub("::", "")
        base.empty? ? "Anon#{object_id.abs.to_s(36)}" : base
      end
    end

    # --- execution ----------------------------------------------------------

    # SPEC.md 5, in order. The order is load-bearing:
    #
    #   base_scope
    #     -> Filter.apply        association filters become id subqueries, so
    #                            the paginated relation is never joined
    #     -> Sort.apply          whitelisted column + :id tiebreaker
    #     -> Cursor.seek         AFTER Sort, because the seek predicate is built
    #                            from the sort column
    #     -> LIMIT page_size + 1 (inside KeysetConnection; the +1 is how
    #                            has_next_page is known without a COUNT)
    #     -> Preloader           (inside KeysetConnection, on the bounded page)
    #     -> KeysetConnection
    #
    # The last two steps are handed to KeysetConnection rather than done here on
    # purpose: page_size clamping decides the LIMIT, and preloading must happen
    # strictly after that LIMIT. Doing it here would mean computing the page
    # size twice and getting invariant 1 wrong the second time.
    def resolve(**args)
      scope = validated_base_scope
      model = scope.klass

      begin
        reject_backward_pagination!(args)

        scope = Filter.apply(scope, self.class.filter_class, args[:filter])

        direction = normalize_direction(args[:sort_direction])
        allowed, requested = sort_request(args)
        column = Sort.column_for(scope, allowed: allowed, field: requested)
        scope = Sort.apply(scope, allowed: allowed, field: requested, direction: direction)

        after = pagination_argument(args, :after)
        scope = apply_seek(scope, model, column, direction, after)

        KeysetConnection.new(
          scope,
          sort_column: column,
          sort_direction: direction,
          preloader: preloader_for(args, model),
          first: pagination_argument(args, :first),
          after: after,
          context: context,
          parent: object,
          field: field,
          **page_size_options
        )
      rescue Error => e
        # SPEC.md 7: a bad cursor, an unsortable field or an unknown filter key
        # is the client's mistake, not a server fault. It surfaces as a GraphQL
        # error rather than a 500.
        raise GraphQL::ExecutionError, e.message
      end
    end

    # Subclasses implement this and nothing else. Multi-tenancy scoping lives
    # here; the gem never adds or removes conditions of its own (SPEC.md 7).
    def base_scope
      raise NotImplementedError, "#{self.class} must define #base_scope"
    end

    private

    def validated_base_scope
      scope = base_scope

      unless defined?(::ActiveRecord::Relation) && scope.is_a?(::ActiveRecord::Relation)
        raise Error,
          "#{self.class}#base_scope must return an ActiveRecord::Relation, got #{scope.class}. " \
          "Every later stage (subquery filters, keyset seek, LIMIT, preload) is relation algebra; " \
          "an Array has already been loaded and cannot be paginated in the database."
      end

      scope
    end

    # Resolves the whitelist and the requested field together, because the
    # answer to "what may be sorted on" depends on whether anything was declared:
    #
    #   sortable_by declared  -> that list, client picks from it
    #   only `paginate cursor:` -> that single column, and it is also the default
    #   neither               -> empty list, and Sort falls back to :id ASC
    def sort_request(args)
      declared = self.class.sortable_fields
      fallback = self.class.cursor_column

      allowed = declared.empty? ? Array(fallback) : declared
      [allowed, args[:sort_by] || fallback]
    end

    def apply_seek(scope, model, column, direction, after)
      return scope if after.nil? || after.to_s.empty?

      # Cast by the column's own type. A datetime cursor that comes back out of
      # JSON as a String would otherwise be compared as a String, which silently
      # drops or repeats rows (SPEC.md 6.4).
      payload = Cursor.decode(after, type: model.type_for_attribute(column.to_s))

      Cursor.seek(
        scope,
        column: column,
        direction: direction,
        sort_value: payload[:sort_value],
        id: payload[:id]
      )
    end

    # SPEC.md §3: v0.1.0 is forward-only, and that limit must be documented,
    # "not hidden" — a request that asks for backward pagination must fail
    # loudly rather than return a plausible-looking wrong page.
    #
    # graphql-ruby's ConnectionExtension publishes `last:`/`before:` on every
    # field whose return type is a Connection (field/connection_extension.rb);
    # that decision is made by the owning field from the return type, not by
    # this resolver's own `argument` declarations, so there is no clean way
    # for a Resolver subclass to stop graphql-ruby from offering them (see the
    # note in FINDING 2's fix for the alternative considered and rejected).
    # ConnectionExtension also strips :first/:last/:before/:after out of the
    # keyword arguments it hands to `resolve` — the same mechanism
    # `pagination_argument` already uses to recover `after:` — so `last:`/
    # `before:` must be read back the same way to be seen at all.
    def reject_backward_pagination!(args)
      last = pagination_argument(args, :last)
      before = pagination_argument(args, :before)
      return if last.nil? && before.nil?

      raise Error,
        "backward pagination (last:/before:) is not supported in v0.1.0 — " \
        "this connection is forward-only. Use first:/after: instead (SPEC.md section 3)."
    end

    def normalize_direction(value)
      normalized = (value || :asc).to_s.downcase.to_sym
      unless Sort::DIRECTIONS.include?(normalized)
        raise Error, "sort direction must be one of #{Sort::DIRECTIONS.inspect}, got #{value.inspect}"
      end

      normalized
    end

    # Builds the callable KeysetConnection runs on the page it just fetched.
    # It is a lambda, not a preload call, precisely so it cannot run early: the
    # connection invokes it after LIMIT (SPEC.md 5, invariant 1). Preloading the
    # relation here would preload the entire filtered set.
    def preloader_for(args, model)
      associations = preload_associations(args, model)
      return nil if associations.empty?

      ->(records) { run_preload(records, associations) }
    end

    def preload_associations(args, model)
      static = self.class.static_preloads

      if self.class.preload_from_selection?
        Preloader.from_lookahead(
          pagination_argument(args, :lookahead),
          model,
          max_depth: self.class.preload_max_depth,
          static: static
        )
      else
        Preloader.merge(static, {})
      end
    end

    def run_preload(records, associations)
      ar_preloader = ::ActiveRecord::Associations::Preloader

      # Rails 7+ takes keywords; 6.1 took positional arguments to #preload.
      if ar_preloader.instance_method(:initialize).parameters.any? { |_kind, key| key == :records }
        ar_preloader.new(records: records, associations: associations).call
      else
        ar_preloader.new.preload(records, associations)
      end

      records
    end

    # Only forwarded when actually declared. GraphQL::Pagination::Connection
    # treats a passed `max_page_size:` as an override even if it is nil, so
    # passing them unconditionally would shadow the schema-level defaults.
    def page_size_options
      options = {}
      options[:default_page_size] = self.class.default_page_size if self.class.has_default_page_size?
      options[:max_page_size] = self.class.max_page_size if self.class.has_max_page_size?
      options
    end

    # `first:` and `after:` do not necessarily reach `resolve`.
    #
    # When the field returns a connection type, graphql-ruby's own
    # ConnectionExtension strips :first/:last/:before/:after out of the keyword
    # arguments before the resolver is called (field/connection_extension.rb),
    # because it expects to apply them itself afterwards. We need `after:`
    # *during* resolve — the seek is a WHERE clause, not a post-filter — so fall
    # back to the runtime's record of the field's real arguments.
    #
    # `args` still wins when present, which covers a resolver on a plain list
    # field and a directly-invoked resolver in a unit test.
    def pagination_argument(args, key)
      return args[key] if args.key?(key)

      current = context && context[:current_arguments]
      keywords = current.respond_to?(:keyword_arguments) ? current.keyword_arguments : current
      keywords.is_a?(Hash) ? keywords[key] : nil
    end
  end
end
