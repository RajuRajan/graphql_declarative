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
  # TODO(you): implement.
  class KeysetConnection < GraphQL::Pagination::Connection
    def nodes
      raise NotImplementedError
    end

    def has_next_page # rubocop:disable Naming/PredicateName
      raise NotImplementedError
    end

    def has_previous_page # rubocop:disable Naming/PredicateName
      false
    end

    def cursor_for(item)
      raise NotImplementedError
    end
  end
end
