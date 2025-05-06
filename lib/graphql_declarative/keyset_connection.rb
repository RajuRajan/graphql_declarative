# frozen_string_literal: true

module GraphqlDeclarative
  # Returned directly from Resolver#resolve — graphql-ruby uses a Connection
  # instance as-is instead of re-wrapping it.
  #
  # Unlike GraphQL::Pagination::RelationConnection, whose #cursor_for encodes an
  # OFFSET (relation_connection.rb:47), this encodes the key tuple
  # (sort_value, id). Offset cursors shift whenever a row is inserted or deleted
  # before the current page, so pages repeat or skip records. See SPEC.md §6.5
  # and spec/stability_spec.rb.
  #
  # has_next_page comes from fetching page_size + 1 rows, never from COUNT.
  # has_previous_page is always false in v0.1.0 (forward-only). Documented, not hidden.
  #
  # Construction (see SPEC.md §5 for where this sits in the pipeline):
  #
  #   KeysetConnection.new(
  #     scope,                       # filtered + sorted + seeked, NOT limited
  #     sort_column: :created_at,    # the column Sort ordered by; :id by default
  #     sort_direction: :asc,        # recorded for callers; not used to query here
  #     preloader: ->(records) { GraphqlDeclarative::Preloader... },
  #     first: args[:first], after: args[:after], context: context,
  #     default_page_size: 25, max_page_size: 100
  #   )
  #
  # The `after:` seek is applied by the caller *before* the relation gets here:
  # the seek predicate belongs with Sort (SPEC.md §5, invariant 2). This class
  # never re-applies it.
  #
  # `items` may be either:
  #   * an ActiveRecord::Relation — this class applies LIMIT page_size + 1,
  #     loads it, trims to page_size, and only then runs `preloader`. That order
  #     is invariant 1 in SPEC.md §5: preloading an unbounded relation preloads
  #     the whole filtered set.
  #   * an Array the caller already bounded to page_size + 1 rows (use
  #     .page_size_for to compute the same limit) — it is trimmed here, and
  #     `preloader` is still applied if given.
  class KeysetConnection < GraphQL::Pagination::Connection
    # Fallbacks used only when neither an explicit override nor a schema-level
    # setting is available (e.g. a connection built outside a query).
    DEFAULT_PAGE_SIZE = 25
    MAX_PAGE_SIZE = 100

    # @return [Symbol] the column the relation is ordered by; also the value
    #   half of every cursor this connection issues.
    attr_reader :sort_column

    # @return [Symbol] :asc or :desc — the direction the relation was sorted in.
    #   Carried so a caller can round-trip it; the seek itself happens upstream.
    attr_reader :sort_direction

    def initialize(items, sort_column: :id, sort_direction: :asc, preloader: nil, **kwargs)
      @sort_column = sort_column.to_sym
      @sort_direction = sort_direction.to_sym
      @preloader = preloader
      super(items, **kwargs)
    end

    # The limit a caller must use if it wants to fetch the page itself:
    # page_size + 1 rows, where the +1 is what makes has_next_page free.
    #
    # `first: 0` returns an empty page (Relay-conformant); only a negative
    # `first:` is an error. The subtlety this class must not repeat: clamping a
    # negative to 0 would let `load_page` fetch 1 row, report `has_next_page:
    # true` off it, and trim `nodes` to `[]` — a page with no rows and no
    # cursor, since `endCursor` is nil when `nodes` is empty. graphql-ruby's own
    # RelationConnection avoids the whole question because `Connection#first`
    # clamps through `limit_pagination_argument`; this class bypasses that by
    # reading `first_value` (the raw, unclamped value) directly, so it validates
    # the bound itself.
    def self.page_size_for(first: nil, default_page_size: nil, max_page_size: nil)
      # The Relay Cursor Connections spec treats first: 0 as valid — an empty
      # page — and only a negative value as an error, so this returns 0 rather
      # than raising. Note what that means: load_page fetches page_size + 1 == 1
      # row, so hasNextPage is true whenever any row matches, with no endCursor
      # to advance from. That is Relay-conformant, and a client that loops on
      # hasNextPage while asking for first: 0 will not progress — but that is
      # the client asking for no rows, not the connection misreporting.
      if first&.negative?
        raise GraphQL::ExecutionError,
          "first: must not be negative (got #{first.inspect}). Omit first: to use the default " \
          "page size."
      end
      return 0 if first == 0

      requested = first || default_page_size || DEFAULT_PAGE_SIZE
      max = max_page_size || MAX_PAGE_SIZE
      [requested, max].min
    end

    # [first || default_page_size, max_page_size].min. A `first:` above
    # max_page_size is clamped, not an error (SPEC.md §6.5).
    def page_size
      @page_size ||= self.class.page_size_for(
        first: first_value,
        default_page_size: configured_default_page_size,
        max_page_size: configured_max_page_size
      )
    end

    def nodes
      load_page
      @nodes
    end

    # True iff the LIMIT page_size + 1 query came back with the extra row.
    # No COUNT — an unbounded count on a filtered set is the thing this avoids.
    def has_next_page # rubocop:disable Naming/PredicateName
      load_page
      @has_next_page
    end

    # Forward-only in v0.1.0 (SPEC.md §3). Stated, not hidden: a client that
    # walks forward never needs it, and honouring it would double the cursor
    # logic for `last:`/`before:`.
    def has_previous_page # rubocop:disable Naming/PredicateName
      false
    end

    # The whole point of the class. RelationConnection encodes an offset here;
    # this encodes the key tuple, so the cursor keeps meaning the same row even
    # when rows are inserted or deleted before the current page.
    def cursor_for(item)
      Cursor.encode(sort_value: sort_value_for(item), id: item.id)
    end

    private

    def load_page
      return if defined?(@nodes)

      fetched = fetch(page_size + 1)
      @has_next_page = fetched.size > page_size
      # first(page_size) also copes with a caller that handed us a longer array.
      @nodes = @has_next_page ? fetched.first(page_size) : fetched
      apply_preloader(@nodes)
      @nodes
    end

    # LIMIT page_size + 1. The extra row is never returned; its existence is the
    # has_next_page answer.
    def fetch(limit)
      if items.is_a?(Array)
        items.first(limit)
      elsif items.respond_to?(:limit)
        items.limit(limit).to_a
      else
        items.first(limit).to_a
      end
    end

    # Preloading runs here — after the page is bounded — never on `items`.
    def apply_preloader(records)
      return records if @preloader.nil? || records.empty?

      @preloader.call(records)
      records
    end

    def sort_value_for(item)
      if item.respond_to?(:[])
        item[sort_column]
      else
        item.public_send(sort_column)
      end
    end

    # The base class reads default/max page size off `context.schema` when no
    # override was given; `context` is nil for a connection built outside a
    # query, so fall back to the documented defaults instead of blowing up.
    def configured_default_page_size
      value = default_page_size if has_default_page_size_override? || context
      value || DEFAULT_PAGE_SIZE
    end

    def configured_max_page_size
      value = max_page_size if has_max_page_size_override? || context
      value || MAX_PAGE_SIZE
    end
  end
end
