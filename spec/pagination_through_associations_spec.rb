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

  let(:filtered) do
    # TODO: replace with the gem's filter application once implemented, e.g.
    #   GraphqlDeclarative::Filter.apply(Course.all, enrollments_status: "active")
    Course.all
  end

  it "returns a full page of DISTINCT records" do
    page = filtered.order(:id).limit(2).to_a

    expect(page.size).to eq(2)
    expect(page.map(&:id).uniq.size).to eq(2)
  end

  it "does not skip records across pages" do
    page1 = filtered.order(:id).limit(2).to_a
    cursor = page1.last.id
    page2 = filtered.order(:id).where("courses.id > ?", cursor).limit(2).to_a

    expect((page1 + page2).map(&:id)).to eq(courses.map(&:id))
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
