# graphql_declarative — technical spec

Status: draft for v0.1.0 · Target: graphql-ruby ~> 2.6, ActiveRecord >= 6.1, Ruby >= 3.0

---

## 1. Problem

Every list endpoint in a graphql-ruby app re-implements the same four concerns by
hand: filtering, sorting, pagination, and preloading. Four hand-written concerns
per endpoint, multiplied across a large API, is where N+1s and pagination bugs
come from — each endpoint is a fresh chance to get it wrong.

Two of those bugs are not just tedium, they are *correctness* failures that most
implementations ship:

**(a) Filtering on an association corrupts pagination.** `joins` multiplies rows.
A course with 3 matching enrollments occupies 3 rows, so `LIMIT 25` returns fewer
than 25 distinct courses and a cursor taken from the last row points into the
middle of a duplicate run — page 2 skips records that were never shown.
`DISTINCT` returns a correct page when sorting by a base-table column, but it
forces the database to materialise and dedupe the entire joined result before
`LIMIT` applies, rejects `ORDER BY` on a joined column, and fails on `json`
columns. Correct but slow and fragile; the subquery is correct and indexable.

**(b) graphql-ruby's own cursors are offsets.** `GraphQL::Pagination::RelationConnection#cursor_for`
(relation_connection.rb:47) encodes `offset.to_s`. If a row is inserted or deleted
before the current page while a client is paginating, every subsequent cursor
points one place off — records repeat or vanish. This is invisible in tests with
static fixtures and shows up in production.

## 2. What this gem is

A resolver *declares* its list behaviour; the gem executes it.

- Filtering, sorting, pagination and preloading declared, not hand-written
- Association filters resolved through id subqueries, so pagination stays correct
- **Keyset** cursors `(sort_value, id)`, not offsets
- Preload set derived from the query's actual selection set, so it cannot drift
  from what the query asks for

## 3. Non-goals for v0.1.0

Explicitly out. Each is a scope trap; adding one costs a session.

- Nested boolean filter trees (`AND` / `OR` / `NOT` groups). Top-level `AND` only.
- Backward pagination (`last:` / `before:`). Forward only. `has_previous_page`
  returns `false` and this is documented, not hidden.
- `totalCount`. It is a second query and an unbounded one; callers who want it
  can add it.
- Polymorphic associations, STI-aware filtering, custom scalar filters.
- Rails generators, railties, engine integration.
- Databases other than PostgreSQL, MySQL and SQLite.

---

## 4. Public API

```ruby
class Types::CourseFilter < GraphqlDeclarative::FilterInput
  filter :title,       :string,   ops: [:eq, :contains, :starts_with]
  filter :published,   :boolean
  filter :created_at,  :datetime, ops: [:gte, :lte]
  filter :author_name, :string,   through: :author,      column: :name
  filter :enrollment_status, :string, through: :enrollments, column: :status
end

class Resolvers::Courses < GraphqlDeclarative::Resolver
  type Types::Course.connection_type, null: false

  filterable_by Types::CourseFilter
  sortable_by   :title, :created_at
  paginate      default_page_size: 25, max_page_size: 100

  preload author: :profile      # always
  preload_from_selection        # plus whatever the query selects

  def base_scope
    Course.where(school_id: context[:school_id])
  end
end
```

The resolver defines `base_scope` and nothing else. `resolve` is provided.

### Generated arguments

`filterable_by` adds one argument `filter:` of the given input type.
`sortable_by` adds `sort_by:` (enum of the whitelisted fields) and `sort_direction:`
(enum `ASC`/`DESC`, default `ASC`). `paginate` adds `first:` and `after:`.

Argument naming inside the filter input, from `filter :title, :string, ops: [...]`:

| op            | argument            | SQL                                  |
|---------------|---------------------|--------------------------------------|
| `eq`          | `title`             | `title = ?`                          |
| `contains`    | `title_contains`    | `title LIKE '%' || ? || '%'`         |
| `starts_with` | `title_starts_with` | `title LIKE ? || '%'`                |
| `ends_with`   | `title_ends_with`   | `title LIKE '%' || ?`                |
| `in`          | `title_in`          | `title IN (?)`                       |
| `gt/gte/lt/lte` | `created_at_gte`  | `created_at >= ?`                    |

`eq` generates the bare name, never `title_eq`.

---

## 5. Execution pipeline

`Resolver#resolve` runs exactly this order. The order is load-bearing.

```
base_scope
  -> Filter.apply        (direct predicates; association filters as id subqueries)
  -> Sort.apply          (whitelisted column + :id tiebreaker)
  -> Cursor seek         (WHERE clause from `after:`)
  -> LIMIT page_size + 1 (the +1 is how has_next_page is known without COUNT)
  -> Preloader           (on the bounded page only)
  -> KeysetConnection
```

Two invariants:

1. **Preload runs last, after `LIMIT`.** Preloading before the page is bounded
   preloads the whole filtered set.
2. **Sort is applied before the cursor seek** because the seek predicate is built
   from the sort column. A cursor is only meaningful against the sort it was
   issued under; see §6.4.

---

## 6. Component contracts

### 6.1 `FilterInput`

Subclass of `GraphQL::Schema::InputObject`.

```ruby
Definition = Struct.new(:name, :type, :ops, :through, :column, keyword_init: true)

def self.filter(name, type, ops: nil, through: nil, column: nil)
def self.definitions  # => {Symbol => Definition}
```

- `ops` defaults per type (`DEFAULT_OPS`); `boolean` is `[:eq]` only.
- `through:` names an association on the model; `column:` the column on that
  association's table. `column:` defaults to `name`.
- `definitions` must be inherited-safe: a subclass sees its parent's definitions.
  Use `Class#inherited` to `dup` the hash, or walk `superclass`.
- Raise `GraphqlDeclarative::Error` at class-definition time for an unknown type
  or an op not valid for that type. Fail at boot, not per-request.

### 6.2 `Filter`

```ruby
Filter.apply(scope, filter_class, args) # => ActiveRecord::Relation
```

- `args` is the `filter:` input as a Hash with symbol keys; `nil` → return `scope`.
- Direct filters chain `where` on `scope`.
- **Association filters never touch `scope` as a join.** Group all `through:`
  filters by association, build ONE subquery per association, then constrain:

```ruby
ids = model.joins(assoc).where(assoc_table => predicates).select(:id)
scope.where(id: ids)
```

  Grouping matters: two filters on the same has_many must intersect within one
  subquery. Two chained subqueries mean "a child matching A and a child matching
  B" — different, and usually not what the caller meant. Document the chosen
  semantic: **one child must satisfy all predicates for that association.**
- Unknown keys in `args` are a programmer error → raise, do not ignore.
- Never interpolate a column name from input. Column identifiers come only from
  `definitions`; values go through bind params.

### 6.3 `Sort`

```ruby
Sort.apply(scope, allowed:, field:, direction: :asc) # => ActiveRecord::Relation
```

- `field` must be in `allowed` or raise. `direction` must be `:asc`/`:desc`.
- Always append `:id` as the final ordering term, in the same direction.
  A non-total order makes keyset pagination non-deterministic — two rows with
  equal sort values can come back in either order between requests, and the
  cursor cannot distinguish them.
- Sorting on a `through:` column is out of scope for v0.1.0. Raise a clear error
  rather than silently joining and reintroducing (a).

### 6.4 `Cursor`

```ruby
Cursor.encode(sort_value:, id:)  # => String (Base64, urlsafe, unpadded)
Cursor.decode(str)               # => {sort_value:, id:}
Cursor.seek(scope, column:, direction:, sort_value:, id:)
```

- Payload is JSON `{"v" => sort_value, "i" => id}`, Base64-urlsafe encoded.
  Opaque to clients by contract; do not document the encoding as stable.
- Seek predicate, ASC:

```sql
(sort_col, id) > (:v, :i)
-- portable form, since SQLite/MySQL row-value support varies:
sort_col > :v OR (sort_col = :v AND id > :i)
```

  DESC flips both comparisons. Encode the sort value as-is and cast on decode
  using the column type — a datetime cursor round-tripping through JSON loses
  sub-second precision otherwise, which silently drops or repeats rows.
- `NULL` sort values: `NULL` never compares true, so rows with a null sort value
  vanish mid-pagination. v0.1.0 requires sortable columns to be `NOT NULL` and
  raises otherwise. Document this; it is the honest limit.
- A malformed or undecodable cursor raises `GraphqlDeclarative::Error`, it does
  not silently reset to page 1.

### 6.5 `KeysetConnection < GraphQL::Pagination::Connection`

Returned directly from `resolve`; graphql-ruby uses a `Connection` instance as-is
rather than re-wrapping it.

- `nodes` — the fetched page, at most `page_size`.
- `has_next_page` — true iff the `LIMIT page_size + 1` query returned the extra
  row. No `COUNT`.
- `has_previous_page` — always `false` in v0.1.0 (forward-only). Documented.
- `cursor_for(item)` — `Cursor.encode(sort_value: item[sort_column], id: item.id)`.
- `page_size` — `[first || default_page_size, max_page_size].min`. A `first:`
  above `max_page_size` is clamped, not an error.

### 6.6 `Preloader`

```ruby
Preloader.from_lookahead(lookahead, model) # => Hash suitable for .preload
```

- Walk `lookahead.selections`. graphql-ruby 2.6 `Lookahead` exposes
  `selections`, `selection(name)`, `field`, `name`, `selects?`.
- Unwrap connection plumbing first: descend through `edges` → `node`, and
  through `nodes`, before matching field names against associations.
- A selection maps to a preload only if `model.reflect_on_association(name)`
  is non-nil. Plain columns are ignored.
- Recurse to build nested hashes: `{author: [:profile], enrollments: []}`.
- Merge with the static `preload` declarations; static wins on conflict.
- Cap recursion depth (default 3) so a deep query cannot generate an enormous
  preload tree.

### 6.7 `Resolver`

```ruby
class << self
  def filterable_by(filter_class)
  def sortable_by(*fields)
  def paginate(default_page_size: 25, max_page_size: 100)
  def preload(*args)
  def preload_from_selection
end

def base_scope  # subclass must implement
```

- Class-level config must be inheritance-safe (same rule as `FilterInput`).
- `resolve(**args)` implements §5 and returns a `KeysetConnection`.
- If `sortable_by` is absent, sort by `:id` ascending.
- `base_scope` returning something that is not an `ActiveRecord::Relation` raises.

---

## 7. Errors and security

- One error class: `GraphqlDeclarative::Error < StandardError`.
- Configuration errors (unknown op, unsortable field, missing `base_scope`) raise
  at class-definition or boot time wherever possible.
- Request errors (bad cursor, unknown filter key) raise
  `GraphQL::ExecutionError` so they surface as GraphQL errors, not 500s.
- **No identifier ever comes from user input.** Column and association names come
  only from `definitions` and the `sortable_by` whitelist. Values are always bind
  parameters. There is no `Arel.sql` on an interpolated string anywhere in the gem.
- Multi-tenancy is the caller's job via `base_scope`; the gem never adds or
  removes scoping conditions.

---

## 8. Test plan

| File | Covers |
|---|---|
| `spec/pagination_through_associations_spec.rb` | **Written.** The (a) contract + 3 specs asserting the naive `joins` bug |
| `spec/filter_input_spec.rb` | Argument generation per op, defaults, inheritance, config-time errors |
| `spec/filter_spec.rb` | Direct predicates; one subquery per association; two filters on one association intersect |
| `spec/sort_spec.rb` | Whitelist enforcement, `:id` tiebreaker appended, direction |
| `spec/cursor_spec.rb` | Round-trip incl. datetime precision, seek predicate ASC/DESC, malformed cursor raises |
| `spec/connection_spec.rb` | `has_next_page` via the +1 row, `page_size` clamping |
| `spec/preloader_spec.rb` | Selection-set walk, `edges`/`node` unwrapping, columns ignored, depth cap |
| `spec/integration_spec.rb` | A real schema, a real query, assert query **count** — this is the N+1 proof |
| `spec/stability_spec.rb` | Insert a row before the current page mid-pagination; keyset holds, offset would not |

`stability_spec.rb` is the executable proof of (b). Reference it in the README
next to the pagination spec.

---

## 9. Milestones

**M1 — filtering.** `FilterInput`, `Filter`, their specs, and swapping the
`filtered` stub in the pagination spec to the real `Filter.apply`. The three
contract specs going green against a real association filter is M1's definition
of done.

**M2 — ordering and paging.** `Sort`, `Cursor`, `KeysetConnection`,
`stability_spec.rb`.

**M3 — preloading and assembly.** `Preloader`, `Resolver`, `integration_spec.rb`
asserting query count.

**M4 — release.** README (problem → before/after → the two correctness sections →
install → API reference), reproducible benchmark in `bench/`, CI green on Ruby
3.2/3.3, v0.1.0 to RubyGems.

## 10. Definition of done

- [ ] All spec files in §8 exist and pass
- [ ] CI green on 3.2 and 3.3
- [ ] README leads with the problem, and cites both correctness specs by path
- [ ] `bench/` produces the query-count table in the README, reproducibly
- [ ] Published as 0.1.0
- [ ] Non-goals from §3 stated plainly in the README

## 11. Decision log

| Decision | Why | Reconsider if |
|---|---|---|
| id subquery, not `DISTINCT` | `DISTINCT` must materialise and dedupe the whole join before LIMIT, breaks `ORDER BY` on joined columns, and fails on json columns | never |
| Keyset, not offset cursors | offsets shift under concurrent writes | never |
| Forward-only pagination | `before:`/`last:` doubles the cursor logic for little use | users ask |
| One subquery per association | "one child satisfies all predicates" is the intuitive reading | users ask for the other |
| Sortable columns must be `NOT NULL` | `NULL` sort values vanish from keyset pagination | v0.2 with NULLS FIRST/LAST |
| No `totalCount` | unbounded second query | opt-in only |
| Preload after `LIMIT` | preloading before bounding loads the whole filtered set | never |
