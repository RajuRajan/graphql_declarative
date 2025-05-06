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
  #
  # TODO(you): implement.
  class Resolver
    def self.filterable_by(filter_class)
      raise NotImplementedError
    end

    def self.sortable_by(*fields)
      raise NotImplementedError
    end

    def self.paginate(cursor:, default_page_size: 25, max_page_size: 100)
      raise NotImplementedError
    end

    def base_scope
      raise NotImplementedError, "#{self.class} must define #base_scope"
    end
  end
end
