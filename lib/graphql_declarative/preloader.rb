# frozen_string_literal: true

module GraphqlDeclarative
  # Builds the preload list from the query's actual selection set, so adding a
  # field to a query never reintroduces an N+1 and no `.includes` list has to be
  # kept in sync by hand.
  #
  # Walk `lookahead` for selections whose field maps to an association on the
  # model, recursing to build a nested preload hash:
  #   {author: [:profile], enrollments: []}
  #
  # Ignore selections that are plain columns, and connection wrapper fields
  # (edges/node) must be unwrapped before matching.
  #
  # TODO(you): implement.
  class Preloader
    def self.from_lookahead(lookahead, model)
      raise NotImplementedError
    end
  end
end
