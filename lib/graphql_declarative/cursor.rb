# frozen_string_literal: true

require "base64"
require "bigdecimal"
require "date"
require "json"
require "time"

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
  # The payload is JSON `{"v" => sort_value, "i" => id}` in urlsafe, unpadded
  # Base64. That encoding is an implementation detail: it is opaque to clients
  # by contract and is not documented as stable.
  class Cursor
    KEY_VALUE = "v"
    KEY_ID = "i"

    # Fractional-second digits kept when a Time is serialised. A datetime that
    # round-trips through `to_s` loses everything after the second, and two rows
    # created in the same second then compare equal to the cursor: the seek
    # `created_at > :v` drops the second one, or `>=` would repeat the first.
    # Nine digits is more than any supported adapter stores.
    TIME_PRECISION = 9

    # @param sort_value [Object] the value of the sort column for this row
    # @param id [Object] the row's primary key
    # @return [String] urlsafe, unpadded Base64
    def self.encode(sort_value:, id:)
      payload = {KEY_VALUE => serialize(sort_value), KEY_ID => id}
      Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
    end

    # @param str [String] a cursor produced by .encode
    # @param type [ActiveModel::Type::Value, Symbol, nil] the type of the sort
    #   column, used to cast the decoded value back. Pass
    #   `model.type_for_attribute(sort_column)` — without it a datetime comes
    #   back as the ISO8601 String it was encoded as, and comparing a String
    #   against a datetime column is adapter-dependent nonsense.
    # @return [Hash] {sort_value:, id:}
    # @raise [Error] on anything malformed. A bad cursor is never silently
    #   treated as "start from the beginning": the client would be handed page 1
    #   while believing it was on page 7, and would never notice.
    def self.decode(str, type: nil)
      raise Error, "cursor is missing" if str.nil? || str.to_s.empty?

      payload = parse(str)
      unless payload.is_a?(Hash) && payload.key?(KEY_VALUE) && payload.key?(KEY_ID)
        raise Error, "malformed cursor: expected keys #{KEY_VALUE.inspect} and #{KEY_ID.inspect}"
      end

      id = payload[KEY_ID]
      raise Error, "malformed cursor: missing id" if id.nil?

      {sort_value: cast(payload[KEY_VALUE], type), id: id}
    end

    # Builds the seek predicate. Portable form, because SQLite's row-value
    # support is version-dependent and MySQL's optimiser treats row-value
    # comparisons differently again:
    #
    #   ASC:   sort_col > :v OR (sort_col = :v AND id > :i)
    #   DESC:  sort_col < :v OR (sort_col = :v AND id < :i)
    #
    # Both halves flip together for DESC — the tiebreaker has to run the same
    # way as the sort column or the tied rows come back in the wrong order and
    # the page walks backwards through them.
    #
    # @param scope [ActiveRecord::Relation, Class]
    # @param column [Symbol, String] sort column, from the `sortable_by`
    #   whitelist only — never from user input (SPEC.md §7).
    # @param direction [Symbol] :asc or :desc
    # @param sort_value [Object] value half of the cursor
    # @param id [Object] id half of the cursor
    # @return [ActiveRecord::Relation]
    def self.seek(scope, column:, direction:, sort_value:, id:)
      direction = direction.to_s.downcase.to_sym
      unless %i[asc desc].include?(direction)
        raise Error, "seek direction must be :asc or :desc, got #{direction.inspect}"
      end

      model = scope.respond_to?(:klass) ? scope.klass : scope
      column = column.to_sym
      unless model.column_names.include?(column.to_s)
        raise Error, "cannot seek on #{column.inspect}: #{model.name} has no such column"
      end

      if sort_value.nil?
        # NULL never compares true, so every row after this one would be lost.
        # v0.1.0 requires sortable columns to be NOT NULL (SPEC.md §6.4); this
        # is where that requirement stops being silent.
        raise Error,
          "cannot seek on a NULL #{column} value: keyset pagination requires the sort column " \
          "to be NOT NULL in v0.1.0 (a NULL never compares true, so the remaining rows vanish)."
      end

      table = model.arel_table
      sort_col = table[column]
      id_col = table[model.primary_key]

      value_bind = bind(model, column, sort_value)
      id_bind = bind(model, model.primary_key, id)

      tie = ->(node) { Arel::Nodes::Grouping.new(sort_col.eq(value_bind).and(node)) }

      predicate =
        if direction == :asc
          sort_col.gt(value_bind).or(tie.call(id_col.gt(id_bind)))
        else
          sort_col.lt(value_bind).or(tie.call(id_col.lt(id_bind)))
        end

      scope.where(predicate)
    end

    # Values are bind parameters, always — the column half of the predicate is
    # an Arel attribute built from a whitelisted name, and the value half never
    # reaches the SQL string. The QueryAttribute also type-casts, so an ISO8601
    # String from a cursor is written to the wire exactly the way the column's
    # own value was.
    def self.bind(model, column, value)
      type = model.type_for_attribute(column.to_s)
      attribute = ActiveRecord::Relation::QueryAttribute.new(column.to_s, value, type)
      Arel::Nodes::BindParam.new(attribute)
    end
    private_class_method :bind

    def self.parse(str)
      json = Base64.urlsafe_decode64(str.to_s)
      JSON.parse(json)
    rescue ArgumentError, JSON::ParserError => e
      raise Error, "malformed cursor: #{e.message}"
    end
    private_class_method :parse

    # Times are serialised at full precision rather than left to JSON, which
    # would call #to_s and truncate to the second. BigDecimal likewise: JSON
    # renders it as a String already, but "0.1e2" is not what comes back out of
    # a decimal column.
    def self.serialize(value)
      case value
      when Time, DateTime
        value.to_time.iso8601(TIME_PRECISION)
      when Date
        value.iso8601
      when BigDecimal
        value.to_s("F")
      else
        value
      end
    end
    private_class_method :serialize

    # `type` may be an ActiveModel type object (anything responding to #cast) or
    # a symbol looked up in ActiveRecord's type registry.
    def self.cast(value, type)
      return value if value.nil? || type.nil?
      return type.cast(value) if type.respond_to?(:cast)

      ActiveRecord::Type.lookup(type.to_sym).cast(value)
    rescue ArgumentError, TypeError => e
      raise Error, "malformed cursor: cannot cast #{value.inspect} (#{e.message})"
    end
    private_class_method :cast
  end
end
