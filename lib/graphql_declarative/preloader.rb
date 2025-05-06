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
  class Preloader
    # Connection plumbing. These are structural, not associations: the entity
    # selections of `courses { edges { node { author { ... } } } }` live two
    # levels below `courses`. Unwrap them BEFORE matching names against
    # associations, otherwise every connection field looks like a leaf column
    # and nothing is ever preloaded.
    #
    # An association is checked for first, so a model that genuinely has an
    # association called `nodes` still wins over the unwrap rule.
    CONNECTION_FIELDS = %i[edges node nodes].freeze

    # A deeply nested query would otherwise let a client dictate the size of the
    # preload tree: `a { b { c { d { ... } } } }` is cheap to write and
    # expensive to serve. Three levels of associations covers the real cases;
    # anything below that is simply not preloaded (it still resolves, just
    # lazily).
    DEFAULT_MAX_DEPTH = 3

    class << self
      # @param lookahead [GraphQL::Execution::Lookahead] the field's lookahead
      # @param model [Class] the ActiveRecord model the scope selects
      # @param max_depth [Integer] association nesting levels to descend
      # @param static [Symbol, Array, Hash, nil] declared preloads to merge in
      # @return [Hash] suitable for `.preload`, e.g. {author: [:profile]}
      def from_lookahead(lookahead, model, max_depth: DEFAULT_MAX_DEPTH, static: nil)
        derived = if lookahead.respond_to?(:selections) && model.respond_to?(:reflect_on_association)
          walk(lookahead, model, Integer(max_depth))
        else
          {}
        end

        denormalize(deep_merge(normalize(static), derived))
      end

      # Merge declared (`preload author: :profile`) preloads with derived ones.
      #
      # Both sides are normalized to a canonical tree and unioned, so a key
      # present in both keeps everything the static declaration asked for and
      # gains whatever the query additionally selected underneath it. Static is
      # authoritative in the sense that nothing it declares can be dropped or
      # flattened by the derived tree -- which is the only "conflict" that can
      # arise between two preload trees. Preloading a little extra is harmless;
      # preloading too little is an N+1.
      #
      # @return [Hash] suitable for `.preload`
      def merge(static, derived)
        denormalize(deep_merge(normalize(static), normalize(derived)))
      end

      private

      # Recursive descent. `depth` counts association hops still allowed, so
      # unwrapping edges/node does not consume budget -- only real associations
      # do.
      def walk(lookahead, model, depth)
        return {} if depth <= 0

        association_selections(lookahead, model).each_with_object({}) do |selection, tree|
          name = selection.name
          child_model = association_model(model.reflect_on_association(name))
          nested = child_model ? walk(selection, child_model, depth - 1) : {}

          # The same association can appear more than once under GraphQL
          # aliases (`a: author { name } b: author { profile }`); union the
          # subtrees rather than letting the last one win.
          tree[name] = deep_merge(tree[name] || {}, nested)
        end
      end

      # Selections on `lookahead` that name an association on `model`, with
      # connection wrappers transparently descended through.
      def association_selections(lookahead, model)
        lookahead.selections.flat_map do |selection|
          name = selection.name

          if name.nil?
            []
          elsif model.reflect_on_association(name)
            [selection]
          elsif CONNECTION_FIELDS.include?(name)
            association_selections(selection, model)
          else
            # A plain column, `cursor`, `pageInfo`, `__typename`: nothing to
            # preload.
            []
          end
        end
      end

      # The model on the far side of an association, or nil when it cannot be
      # resolved. Polymorphic associations have no single target class, and are
      # a non-goal for v0.1.0 -- the association itself is still preloaded, we
      # just do not descend into it.
      def association_model(reflection)
        return nil if reflection.nil?
        return nil if reflection.polymorphic?

        reflection.klass
      rescue NameError
        nil
      end

      # --- canonical tree helpers -------------------------------------------
      #
      # Internally a preload tree is Hash{Symbol => Hash}, recursively, with an
      # empty hash meaning "leaf". That form merges without special cases. The
      # public methods denormalize it back to the `.preload` shape the spec
      # documents: {author: [:profile], enrollments: []}.

      def normalize(spec)
        case spec
        when nil then {}
        when Symbol then {spec => {}}
        when String then {spec.to_sym => {}}
        when Array then spec.each_with_object({}) { |part, tree| deep_merge!(tree, normalize(part)) }
        when Hash
          spec.each_with_object({}) do |(key, value), tree|
            deep_merge!(tree, {key.to_sym => normalize(value)})
          end
        else
          raise Error, "cannot interpret #{spec.inspect} as a preload declaration"
        end
      end

      def deep_merge(left, right)
        deep_merge!(left.dup, right)
      end

      def deep_merge!(left, right)
        right.each do |key, subtree|
          left[key] = left.key?(key) ? deep_merge(left[key], subtree) : subtree
        end
        left
      end

      def denormalize(tree)
        tree.transform_values { |subtree| entries(subtree) }
      end

      def entries(tree)
        tree.map { |key, subtree| subtree.empty? ? key : {key => entries(subtree)} }
      end
    end
  end
end
