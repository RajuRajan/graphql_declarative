# frozen_string_literal: true

# ---------------------------------------------------------------------------
# THE HEADLINE SPEC. This is the reason the gem exists — write the
# implementation until this passes, and reference this file in the README.
#
# Filtering on a has_many with `joins` multiplies rows: a course with 3 active
# enrollments appears 3 times. LIMIT 2 then returns fewer than 2 *distinct*
# courses, and the cursor for "last row on this page" points into the middle of
# a duplicate run — so page 2 skips records that were never shown.
#
# `DISTINCT` does not save you: it fixes the count but breaks ORDER BY on a
# joined column, and still can't produce a stable cursor.
#
# The fix is to resolve association filters through an id subquery so the base
# relation is never joined:
#
#   ids = Course.joins(:enrollments).where(enrollments: {status: "active"}).select(:id)
#   scope.where(id: ids)
# ---------------------------------------------------------------------------

RSpec.describe "pagination through association filters" do
  let!(:courses) do
    # 4 courses, each with a different number of ACTIVE enrollments.
    # Every course qualifies for the filter; only the row counts differ.
    [3, 1, 2, 1].each_with_index.map do |active_count, i|
      course = Course.create!(title: "Course #{i}", published: true)
      active_count.times { course.enrollments.create!(status: "active") }
      course.enrollments.create!(status: "cancelled")
      course
    end
  end

  # The declaration. `through: :enrollments` is what makes this a has_many
  # filter; `column: :status` names the column on the ENROLLMENTS table. Both
  # identifiers come from here and only from here (SPEC.md 7).
  let(:filter_class) do
    Class.new(GraphqlDeclarative::FilterInput) do
      graphql_name "PaginationContractCourseFilter"
      filter :enrollment_status, :string, through: :enrollments, column: :status, ops: [:eq]
    end
  end

  # The real thing. Filter.apply resolves the association filter to
  # `WHERE courses.id IN (SELECT ...)`, so `filtered` is an un-joined relation
  # over courses -- one row per course, whatever the enrollment counts are.
  let(:filtered) do
    GraphqlDeclarative::Filter.apply(Course.all, filter_class, enrollment_status: "active")
  end

  it "does not join the relation it hands back" do
    expect(filtered.joins_values).to be_empty
    expect(filtered.to_sql).to match(/"courses"\."id" IN \(SELECT/)
  end

  it "returns a full page of DISTINCT records" do
    page = filtered.order(:id).limit(2).to_a

    expect(page.size).to eq(2)
    expect(page.map(&:id).uniq.size).to eq(2)
  end

  it "does not skip records across pages" do
    # The real gem pagination path — Sort.apply + Cursor.encode/decode/seek —
    # not a hand-rolled `where("courses.id > ?", ...)`. A hand-rolled seek
    # would still pass even if Cursor.seek itself built the wrong predicate
    # (e.g. forgot the tiebreaker, or used the wrong comparison operator for
    # the direction), because it never calls that code. Walking every page in
    # page_size 1 (not just two pages) also proves the walk holds all the way
    # to the end, not just once.
    allowed = []
    column = GraphqlDeclarative::Sort.column_for(filtered, allowed: allowed, field: nil)
    sorted = GraphqlDeclarative::Sort.apply(filtered, allowed: allowed, field: nil, direction: :asc)

    seen = []
    cursor_after = nil

    # Bounded, not `loop do ... end`: a broken seek predicate (e.g. `>=`
    # instead of `>` on the tiebreaker) can make the same row match forever,
    # which must show up as a *failing* assertion below, not a hung suite.
    (courses.size + 1).times do
      page = if cursor_after
        decoded = GraphqlDeclarative::Cursor.decode(cursor_after)
        GraphqlDeclarative::Cursor.seek(
          sorted, column: column, direction: :asc,
          sort_value: decoded[:sort_value], id: decoded[:id]
        ).limit(1).to_a
      else
        sorted.limit(1).to_a
      end

      break if page.empty?

      record = page.first
      seen << record.id
      cursor_after = GraphqlDeclarative::Cursor.encode(
        sort_value: record.public_send(column), id: record.id
      )
    end

    expect(seen).to eq(courses.map(&:id))
  end

  it "counts each matching record once" do
    expect(filtered.count).to eq(4)
  end
end

# ---------------------------------------------------------------------------
# Proof the naive approach is broken. These assert the WRONG behaviour on
# purpose, so the bug is demonstrable and cannot silently regress. This is the
# before/after evidence for the README.
# ---------------------------------------------------------------------------
RSpec.describe "the naive `joins` approach (documenting the bug)" do
  let!(:courses) do
    [3, 1, 2, 1].each_with_index.map do |active_count, i|
      course = Course.create!(title: "Course #{i}", published: true)
      active_count.times { course.enrollments.create!(status: "active") }
      course
    end
  end

  let(:naive) { Course.joins(:enrollments).where(enrollments: {status: "active"}) }

  it "returns duplicate rows, so a page of 2 holds fewer than 2 records" do
    page = naive.order(:id).limit(2).to_a

    expect(page.size).to eq(2)
    expect(page.map(&:id).uniq.size).to eq(1) # BUG: both rows are the same course
  end

  it "skips records entirely on page 2" do
    page1 = naive.order(:id).limit(2).to_a
    page2 = naive.order(:id).where("courses.id > ?", page1.last.id).limit(2).to_a
    seen = (page1 + page2).map(&:id).uniq

    expect(seen.size).to be < 4 # BUG: courses vanish between pages
  end

  it "over-counts" do
    expect(naive.count).to eq(7) # BUG: 4 courses, 7 enrollment rows
  end
end
