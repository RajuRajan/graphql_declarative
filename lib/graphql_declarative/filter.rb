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
  # TODO(you): implement.
  class Filter
    def self.apply(scope, filter_class, args)
      raise NotImplementedError
    end
  end
end
