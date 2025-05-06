# frozen_string_literal: true

module GraphqlDeclarative
  # Opaque keyset cursors. Encode the tuple (sort_value, id) — never the offset,
  # and never the sort value alone, or ties silently drop records.
  #
  #   Cursor.encode(sort_value: "Ruby 101", id: 42)
  #   Cursor.decode("eyJzIjoiUnVieSAxMDEiLCJpZCI6NDJ9")
  #
  # Seek predicate for ASC:  (sort_col, id) > (sort_value, id)
  # Emulate row-value comparison where the adapter lacks it:
  #   sort_col > :s OR (sort_col = :s AND id > :id)
  #
  # TODO(you): implement encode/decode and the seek predicate builder.
  class Cursor
    def self.encode(sort_value:, id:)
      raise NotImplementedError
    end

    def self.decode(str)
      raise NotImplementedError
    end
  end
end
