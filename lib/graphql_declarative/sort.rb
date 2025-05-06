# frozen_string_literal: true

module GraphqlDeclarative
  # Whitelisted ordering. Never interpolate a client-supplied column name.
  # Always append the model's primary key as the final tiebreaker so ordering
  # is total — a non-total order makes keyset pagination non-deterministic.
  #
  #   Sort.apply(Course.all, allowed: [:title, :created_at], field: "title", direction: :desc)
  #   # => ORDER BY "courses"."title" DESC, "courses"."id" DESC
  #
  # Two rows with the same `title` would otherwise come back in whatever order
  # the adapter felt like this time. A cursor built from (title, id) cannot tell
  # them apart if the primary key is not part of the ORDER BY, so page 2 either
  # repeats or skips the tied rows. The tiebreaker goes in the *same* direction
  # as the sort column, because Cursor.seek compares both halves in that
  # direction.
  #
  # The tiebreaker is always `model.primary_key`, not a hardcoded `:id`. Sort
  # and Cursor derive it from the same source (`ActiveRecord::Base#primary_key`)
  # for exactly this reason: if Sort ordered by one column and Cursor seeked on
  # another, the total order the keyset depends on would not exist. A model
  # whose primary key is not "id" (e.g. a `uuid` column) would then get an
  # ORDER BY and a WHERE clause built from different columns — on Postgres/MySQL
  # a hard UndefinedColumn error, on SQLite a silent, wrong fallback to rowid.
  #
  # Identifier safety (SPEC.md §7): `field` is only ever used after it has been
  # matched against `allowed` — the value that reaches ActiveRecord is the
  # canonical name from the whitelist, never the caller's string. Ordering is
  # expressed as a Hash (`order(title: :asc)`) so ActiveRecord quotes the
  # identifier itself; there is no Arel.sql on an interpolated string here.
  class Sort
    DIRECTIONS = %i[asc desc].freeze

    # @param scope [ActiveRecord::Relation, Class] relation (or model) to order
    # @param allowed [Array<Symbol, String, #name>] the `sortable_by` whitelist.
    #   Entries may be plain names or FilterInput::Definition structs; a
    #   definition carrying `through:` is rejected (see below).
    # @param field [Symbol, String, nil] requested sort field. `nil` means "no
    #   sort declared" and orders by the primary key, which SPEC.md §6.7 makes
    #   the default.
    # @param direction [Symbol, String] :asc or :desc
    # @return [ActiveRecord::Relation]
    def self.apply(scope, allowed:, field: nil, direction: :asc)
      direction = normalize_direction(direction)
      model = model_for(scope)
      tiebreaker = primary_key_for(model)
      field = resolve_field(model, allowed, field, tiebreaker)

      # reorder, not order: the declared sort is authoritative. Appending to a
      # default_scope's ORDER BY would leave some other column as the leading
      # term, and the seek predicate is built from *our* leading term.
      return scope.reorder(tiebreaker => direction) if field == tiebreaker

      scope.reorder(field => direction).order(tiebreaker => direction)
    end

    # @return [Symbol] the column that was actually ordered by — the caller
    #   needs it to build cursors, and it may differ from `field` (nil => the
    #   model's primary key).
    def self.column_for(scope, allowed:, field: nil)
      model = model_for(scope)
      resolve_field(model, allowed, field, primary_key_for(model))
    end

    def self.normalize_direction(direction)
      normalized = direction.to_s.downcase.to_sym
      unless DIRECTIONS.include?(normalized)
        raise Error, "sort direction must be one of #{DIRECTIONS.inspect}, got #{direction.inspect}"
      end

      normalized
    end
    private_class_method :normalize_direction

    # The single source of truth for the tiebreaker column, shared with
    # Cursor.seek (which calls `model.primary_key` directly). Both must derive
    # it the same way or the ORDER BY and the seek predicate reference
    # different columns and the keyset's total order stops existing.
    def self.primary_key_for(model)
      pk = model.primary_key
      if pk.nil?
        raise Error,
          "#{model.name} has no primary key declared. Keyset pagination requires a single-column " \
          "primary key to use as the sort tiebreaker."
      end

      # Rails 7.1+ composite primary keys return an Array. A keyset needs one
      # totally-ordered tiebreaker column, so this is a clear refusal rather
      # than a NoMethodError on Array#to_sym.
      if pk.is_a?(Array)
        raise Error,
          "#{model.name} has a composite primary key (#{pk.join(", ")}). Keyset pagination " \
          "requires a single-column primary key to use as the sort tiebreaker; composite keys " \
          "are not supported in v0.1.0."
      end

      pk.to_sym
    end
    private_class_method :primary_key_for

    # Resolves the requested field against the whitelist and returns the
    # canonical, declaration-supplied name. Everything that can go wrong is a
    # raise: an unsortable field must not silently fall back to the tiebreaker,
    # or a client gets a page ordered differently from the one its cursor was
    # issued under.
    def self.resolve_field(model, allowed, field, tiebreaker)
      return tiebreaker if field.nil? || field.to_s.empty?

      requested = field.to_s
      # The primary key is implicitly sortable — it is the tiebreaker on
      # every other sort.
      return tiebreaker if requested == tiebreaker.to_s

      name, entry = match(allowed, requested)
      if name.nil?
        raise Error,
          "#{requested.inspect} is not sortable. Declared sortable fields: " \
          "#{whitelist(allowed).map(&:first).inspect}"
      end

      # A `through:` filter names a column on another table. Ordering by it
      # would mean joining, and a join multiplies rows — exactly the pagination
      # corruption this gem exists to avoid (SPEC.md §1a). Out of scope for
      # v0.1.0, so say so instead of silently joining.
      if entry.respond_to?(:through) && entry.through
        raise Error,
          "cannot sort by #{name.inspect}: it is declared `through: #{entry.through.inspect}`. " \
          "Sorting on an association column is not supported in v0.1.0 — a join multiplies rows " \
          "and breaks keyset pagination."
      end

      unless model.column_names.include?(name)
        raise Error,
          "cannot sort by #{name.inspect}: #{model.name} has no such column. " \
          "Sorting is limited to columns on the model's own table in v0.1.0."
      end

      # SPEC.md §6.4: keyset pagination requires sortable columns to be
      # NOT NULL and raises otherwise. NULL never compares true, so a row with
      # a null sort value can never be reached by the seek predicate — it just
      # vanishes, and (depending on direction and adapter) either drops rows
      # while reporting has_next_page: false, or wedges the client behind rows
      # it can never seek past. This is where that requirement stops being
      # silent: as early as this gem can know the column's nullability (the
      # first time it is asked to sort by it), not buried in a per-request
      # NULL that only shows up once real data has one.
      # Deliberately not `column&.null`: safe navigation would fail OPEN here.
      # column_names and columns_hash are not guaranteed to agree (view-backed
      # models, attributes declared with `attribute`), and a missing entry must
      # not mean "no NOT NULL check" — that is how the silent-row-loss bug this
      # guard exists to prevent gets back in.
      column = model.columns_hash[name]
      if column.nil?
        raise Error,
          "cannot sort by #{name.inspect}: #{model.name} reports no column metadata for it, " \
          "so its nullability cannot be verified. Keyset pagination requires a NOT NULL " \
          "sortable column."
      end

      if column.null
        raise Error,
          "cannot sort by #{name.inspect}: #{model.name}##{name} (#{model.table_name}.#{name}) " \
          "allows NULL. Keyset pagination requires sortable columns to be NOT NULL — a NULL sort " \
          "value never compares true, so rows carrying it are silently dropped mid-pagination while " \
          "has_next_page reports false, or (ascending) leave later rows permanently unreachable. " \
          "Add a NOT NULL constraint to #{model.table_name}.#{name}, or remove it from `sortable_by`."
      end

      name.to_sym
    end
    private_class_method :resolve_field

    # Exact match first, then case-insensitive — a GraphQL enum may arrive as
    # "CREATED_AT". Either way the name that gets used is the whitelist's own.
    def self.match(allowed, requested)
      list = whitelist(allowed)
      list.find { |name, _| name == requested } ||
        list.find { |name, _| name.casecmp?(requested) } ||
        [nil, nil]
    end
    private_class_method :match

    def self.whitelist(allowed)
      Array(allowed).map do |entry|
        name = (entry.is_a?(Symbol) || entry.is_a?(String)) ? entry : entry.name
        [name.to_s, entry]
      end
    end
    private_class_method :whitelist

    def self.model_for(scope)
      scope.respond_to?(:klass) ? scope.klass : scope
    end
    private_class_method :model_for
  end
end
