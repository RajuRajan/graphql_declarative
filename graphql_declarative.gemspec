# frozen_string_literal: true

require_relative "lib/graphql_declarative/version"

Gem::Specification.new do |spec|
  spec.name = "graphql_declarative"
  spec.version = GraphqlDeclarative::VERSION
  spec.authors = ["Raja Rajan"]
  spec.email = ["rajuart678@gmail.com"]

  spec.summary = "Declarative filtering, sorting, cursor pagination, and preloading for graphql-ruby resolvers."
  spec.description = "Declare filtering, sorting, cursor pagination, and preloading on a graphql-ruby " \
    "resolver instead of hand-writing them per endpoint. Pagination stays correct through " \
    "association filters, and preloading is derived from the query's selection set."
  spec.homepage = "https://github.com/RajuRajan/graphql_declarative"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "graphql", "~> 2.0"
  # Floor is 7.0, not 6.1: ActiveSupport 6.1 does not load on the Ruby versions this
  # gem supports. Every version in the range is exercised by the CI matrix.
  spec.add_dependency "activerecord", ">= 7.0", "< 9.0"

  spec.add_development_dependency "sqlite3", "~> 2.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
