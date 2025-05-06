# frozen_string_literal: true

module GraphqlDeclarative
  # Whitelisted ordering. Never interpolate a client-supplied column name.
  # Always append :id as the final tiebreaker so ordering is total — a
  # non-total order makes keyset pagination non-deterministic.
  #
  # TODO(you): implement.
  class Sort
    def self.apply(scope, allowed:, field:, direction: :asc)
      raise NotImplementedError
    end
  end
end
