# graphql_declarative

Declarative filtering, sorting, cursor pagination and preloading for
[graphql-ruby](https://github.com/rmosolgo/graphql-ruby) resolvers.

In a large GraphQL API, every list endpoint re-implements the same four concerns
by hand. Four hand-written concerns per endpoint, across a hundred endpoints, is
where N+1s and pagination bugs come from — each endpoint is a fresh chance to get
it wrong.

Two of those bugs are not tedium. They are correctness failures that most
implementations ship, and both are invisible in a test suite with static
fixtures.

<!-- TODO(raja): one paragraph in your own voice on WHY you built this — the
     production experience behind it. This is the paragraph people believe or
     don't. Keep it factual and first-person; do not claim employer work as
     this gem's code. -->

## Before

```ruby
class Resolvers::Courses < GraphQL::Schema::Resolver
  type Types::Course.connection_type, null: false

  argument :title_contains,    String,  required: false
  argument :enrollment_status, String,  required: false
  argument :sort_by,           String,  required: false

  def resolve(title_contains: nil, enrollment_status: nil, sort_by: nil, first: 25, after: nil)
    scope = Course.where(school_id: context[:school_id])
    scope = scope.where("title LIKE ?", "%#{title_contains}%") if title_contains
    scope = scope.joins(:enrollments)
                 .where(enrollments: {status: enrollment_status}) if enrollment_status
    scope = scope.order(sort_by || :id)
    scope = scope.offset(Base64.decode64(after).to_i) if after
    scope.limit(first).includes(:author)
  end
end
```

Four bugs: the `joins` corrupts pagination, the offset cursor breaks under
concurrent writes, `order(sort_by)` interpolates user input, and `includes(:author)`
is hardcoded so any new association in the query reintroduces an N+1.

## After

```ruby
class Types::CourseFilter < GraphqlDeclarative::FilterInput
  filter :title,             :string, ops: [:contains]
  filter :enrollment_status, :string, through: :enrollments, column: :status
end

class Resolvers::Courses < GraphqlDeclarative::Resolver
  type Types::Course.connection_type, null: false

  filterable_by Types::CourseFilter
  sortable_by   :title, :created_at
  paginate      default_page_size: 25, max_page_size: 100
  preload_from_selection

  def base_scope
    Course.where(school_id: context[:school_id])
  end
end
```

No `resolve`. You declare what is allowed; the gem builds the query.

## Correctness 1: association filters must not join the paginated relation

`joins` multiplies rows. A course with 3 matching enrollments occupies 3 rows, so
`LIMIT 25` returns fewer than 25 distinct courses, and a cursor taken from the
last row points into the middle of a duplicate run — page 2 skips records that
were never shown. `DISTINCT` fixes the count but breaks `ORDER BY` on a joined
column and still cannot produce a stable cursor.

Four courses with 3, 1, 2 and 1 active enrollments, page size 2:

| | page 1 | page 2 | `count` |
|---|---|---|---|
| `joins` | `[A, A]` | skips records | `7` |
| this gem | `[A, B]` | `[C, D]` | `4` |

`through:` filters are resolved into an id subquery, so the paginated relation is
never joined:

```sql
SELECT "courses".* FROM "courses"
WHERE "courses"."published" = TRUE
  AND "courses"."id" IN (SELECT "courses"."id" FROM "courses"
                         INNER JOIN "enrollments" ON "enrollments"."course_id" = "courses"."id"
                         WHERE "enrollments"."status" = 'active')
  AND ("courses"."title" > 'B' OR ("courses"."title" = 'B' AND "courses"."id" > 3))
ORDER BY "courses"."title" ASC, "courses"."id" ASC
LIMIT 3
```

Proof: [`spec/pagination_through_associations_spec.rb`](spec/pagination_through_associations_spec.rb).
Three specs assert the contract; three more assert the broken `joins` behaviour on
purpose, so the bug stays demonstrable and cannot silently return.

## Correctness 2: cursors must be keys, not offsets

graphql-ruby's `GraphQL::Pagination::RelationConnection#cursor_for` encodes
`offset.to_s` ([relation_connection.rb:47](https://github.com/rmosolgo/graphql-ruby/blob/master/lib/graphql/pagination/relation_connection.rb)).
If a row is inserted or deleted before the current page while a client is
paginating, every later cursor points one place off — records repeat or vanish.

This gem encodes the tuple `(sort_value, id)` and seeks:

```sql
sort_col > :v OR (sort_col = :v AND id > :i)
```

Row-value comparison is deliberately avoided; SQLite and MySQL support varies.

Proof: [`spec/stability_spec.rb`](spec/stability_spec.rb) — paginate, insert a row
before the current page, then fetch page 2. The keyset walk returns each record
exactly once; the offset walk repeats one.

<!-- TODO(raja): if you have a production war story about either failure mode,
     two sentences here is worth more than the rest of this README. Only if it
     is genuinely yours. -->

## Preloading

`preload_from_selection` walks the query's selection set and preloads the
associations the query actually asked for, so the preload list cannot drift from
the query the way a hardcoded `includes` does.

Page of 25, from 2,000 courses / 200 authors / 6,000 enrollments, selecting
`author { name }` and `enrollments { status }`:

| | queries | time |
|---|---|---|
| no preloading | 51 | 5.3 ms |
| preload derived from the selection set | 3 | 2.0 ms |

Reproduce with `ruby bench/query_count.rb`.

## Safety

Column, table and association identifiers come only from `filter` declarations
and the `sortable_by` whitelist — never from user input. Values are always bind
parameters, `LIKE` metacharacters are escaped with an explicit `ESCAPE` clause,
and there is no `Arel.sql` on an interpolated string anywhere in the gem.
`sortable_by` rejects anything not declared, so `sortBy: "title; DROP TABLE courses"`
raises rather than reaching SQL.

## Installation

```ruby
gem "graphql_declarative"
```

Requires Ruby >= 3.0, graphql ~> 2.0, ActiveRecord >= 6.1. Tested against
PostgreSQL, MySQL and SQLite.

## API

### `FilterInput`

```ruby
filter :title,       :string,   ops: [:eq, :contains, :starts_with, :ends_with, :in]
filter :created_at,  :datetime, ops: [:gte, :lte]
filter :author_name, :string,   through: :author, column: :name
```

`:eq` generates the bare argument name (`title:`); every other op suffixes it
(`title_contains:`, `created_at_gte:`). `through:` names an association;
`column:` defaults to the filter name.

Multiple filters on the same association intersect **within one subquery** — one
child row must satisfy all predicates for that association.

### `Resolver`

| Declaration | Adds |
|---|---|
| `filterable_by FilterClass` | `filter:` argument |
| `sortable_by :a, :b` | `sort_by:` and `sort_direction:` enums |
| `paginate default_page_size:, max_page_size:` | `first:` and `after:` |
| `preload author: :profile` | static preload, always applied |
| `preload_from_selection` | preload derived from the query |

Pipeline order, which is load-bearing:

```
base_scope -> Filter -> Sort -> cursor seek -> LIMIT n+1 -> Preloader -> Connection
```

Preload runs after `LIMIT` — preloading before the page is bounded loads the
whole filtered set. Sort runs before the seek, because the seek predicate is
built from the sort column.

## Limitations in v0.1.0

Stated plainly, because each one is a place this gem will not protect you:

- **Forward pagination only.** `last:`/`before:` raise a clear error rather than
  being silently ignored.
- **Sortable columns must be `NOT NULL`.** A `NULL` sort value never compares
  true, so rows carrying it would vanish mid-pagination. Declaring a nullable
  column raises — but at first use, not at boot, so a misdeclared resolver ships
  green and fails on the first request that selects it.
- **Single-column primary keys only.** Composite keys raise.
- **Top-level `AND` only.** No nested `AND`/`OR`/`NOT` filter trees.
- **No `totalCount`.** It is an unbounded second query.
- **Cursors do not record the sort they were issued under.** Changing `sort_by`
  mid-pagination gives wrong results rather than an error.
- **A malformed cursor id casts silently.** A garbage id may yield a
  valid-looking page instead of a "malformed cursor" error.
- **The id subquery is built from the model, not from `base_scope`.** In a
  multi-tenant app the subquery scans across tenants before the outer query
  intersects it back down. Correct, but not free.
- No polymorphic associations, STI-aware filtering, custom scalar filters, or
  Rails generators.

## Development

```
bin/setup
bundle exec rspec
bundle exec standardrb
ruby bench/query_count.rb
```

`SPEC.md` is the design document: component contracts, the pipeline invariants,
and a decision log recording why each tradeoff was made.

## License

MIT
