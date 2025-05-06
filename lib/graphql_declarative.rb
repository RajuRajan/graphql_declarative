# frozen_string_literal: true

require "graphql"
require_relative "graphql_declarative/version"

module GraphqlDeclarative
  class Error < StandardError; end

  autoload :FilterInput, "graphql_declarative/filter_input"
  autoload :Filter, "graphql_declarative/filter"
  autoload :Sort, "graphql_declarative/sort"
  autoload :Cursor, "graphql_declarative/cursor"
  autoload :KeysetConnection, "graphql_declarative/keyset_connection"
  autoload :Preloader, "graphql_declarative/preloader"
  autoload :Resolver, "graphql_declarative/resolver"
end
