# frozen_string_literal: true

module GraphqlDeclarative
  # A GraphQL::Schema::InputObject built from `filter` declarations.
  #
  #   class Types::CourseFilter < GraphqlDeclarative::FilterInput
  #     filter :title,       :string,   ops: [:eq, :contains, :starts_with]
  #     filter :published,   :boolean
  #     filter :created_at,  :datetime, ops: [:gte, :lte]
  #     filter :author_name, :string,   through: :author, column: :name
  #   end
  #
  # Each (name, op) pair generates one argument: :title_contains, :created_at_gte.
  # `:eq` generates the bare name (:title), not :title_eq.
  #
  # TODO(you): subclass GraphQL::Schema::InputObject, implement `.filter` to
  # register a Definition and call `argument` for each op. Keep the registry on
  # the class so Filter.apply can read it back.
  class FilterInput
    DEFAULT_OPS = {
      string: %i[eq contains starts_with ends_with in],
      integer: %i[eq gt gte lt lte in],
      float: %i[eq gt gte lt lte],
      boolean: %i[eq],
      datetime: %i[eq gt gte lt lte]
    }.freeze

    Definition = Struct.new(:name, :type, :ops, :through, :column, keyword_init: true)

    def self.filter(name, type, ops: nil, through: nil, column: nil)
      raise NotImplementedError
    end

    def self.definitions
      @definitions ||= {}
    end
  end
end
