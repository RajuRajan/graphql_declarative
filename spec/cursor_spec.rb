# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Cursor (SPEC.md §6.4).
#
# A cursor is the tuple (sort_value, id), never an offset. Three things are
# tested here and each corresponds to a way real pagination breaks:
#
#   * round-trip fidelity, especially for datetimes. JSON's default rendering
#     of a Time truncates to the second; two rows created in the same second
#     then compare equal to the cursor and one of them is silently dropped.
#   * the seek predicate, in both directions. Both halves must flip together.
#   * malformed input raises. A bad cursor must NOT quietly reset to page 1 —
#     the client would be served page 1 while believing it was on page 7.
# ---------------------------------------------------------------------------

RSpec.describe GraphqlDeclarative::Cursor do
  describe "encoding" do
    it "produces urlsafe, unpadded Base64" do
      cursor = described_class.encode(sort_value: "Ruby 101", id: 42)

      expect(cursor).to match(/\A[A-Za-z0-9_-]+\z/)
      expect(cursor).not_to include("=")
    end

    it "encodes the id as well as the sort value, so ties are distinguishable" do
      a = described_class.encode(sort_value: "Same", id: 1)
      b = described_class.encode(sort_value: "Same", id: 2)

      expect(a).not_to eq(b)
    end

    it "is not an offset" do
      # RelationConnection#cursor_for encodes offset.to_s; this encodes the key.
      # Two rows at the same offset in different result sets must not share a
      # cursor.
      expect(described_class.encode(sort_value: "A", id: 7))
        .not_to eq(described_class.encode(sort_value: "B", id: 7))
    end
  end

  describe "round-trip" do
    it "round-trips a string" do
      payload = described_class.decode(described_class.encode(sort_value: "Ruby 101", id: 42))

      expect(payload).to eq(sort_value: "Ruby 101", id: 42)
    end

    it "round-trips an integer" do
      payload = described_class.decode(described_class.encode(sort_value: 17, id: 42))

      expect(payload[:sort_value]).to eq(17)
    end

    it "round-trips a boolean" do
      payload = described_class.decode(described_class.encode(sort_value: false, id: 1))

      expect(payload[:sort_value]).to be(false)
    end

    it "round-trips a datetime WITHOUT losing sub-second precision" do
      # The whole reason serialize/1 does not just let JSON call #to_s.
      time = Time.utc(2024, 6, 1, 12, 30, 45, 123_456)
      type = Course.type_for_attribute("created_at")

      payload = described_class.decode(described_class.encode(sort_value: time, id: 1), type: type)

      expect(payload[:sort_value].to_f).to be_within(0.000001).of(time.to_f)
      expect(payload[:sort_value].usec).to eq(123_456)
    end

    it "casts back to a Time when given the column type" do
      time = Time.utc(2024, 6, 1, 12, 30, 45)
      type = Course.type_for_attribute("created_at")

      payload = described_class.decode(described_class.encode(sort_value: time, id: 1), type: type)

      expect(payload[:sort_value]).to be_a(Time)
    end

    it "returns the raw ISO8601 string when no type is supplied" do
      # Comparing that string against a datetime column is adapter-dependent
      # nonsense — which is exactly why Resolver always passes the type.
      time = Time.utc(2024, 6, 1, 12, 30, 45)

      payload = described_class.decode(described_class.encode(sort_value: time, id: 1))

      expect(payload[:sort_value]).to be_a(String)
    end

    it "round-trips a datetime through a real column value" do
      # Sub-second precision is the whole point of this spec (see the header
      # comment on TIME_PRECISION in cursor.rb) — two rows created in the same
      # second must not compare equal to a cursor built from one of them.
      # Asserting only `.to_i` equality is exactly the second-level truncation
      # this test exists to rule out: reintroduce it (e.g. set
      # Cursor::TIME_PRECISION to 0) and a `.to_i` assertion still passes,
      # because `.to_i` throws away the same precision the bug throws away.
      course = Course.create!(title: "T", created_at: Time.utc(2024, 6, 1, 12, 30, 45, 654_321))
      course.reload
      type = Course.type_for_attribute("created_at")

      payload = described_class.decode(
        described_class.encode(sort_value: course.created_at, id: course.id),
        type: type
      )

      expect(payload[:sort_value].usec).to eq(course.created_at.usec)
      expect(payload[:sort_value].to_f).to be_within(0.000001).of(course.created_at.to_f)
      expect(payload[:id]).to eq(course.id)
    end
  end

  describe "malformed cursors" do
    it "raises for nil" do
      expect { described_class.decode(nil) }.to raise_error(GraphqlDeclarative::Error, /missing/)
    end

    it "raises for an empty string" do
      expect { described_class.decode("") }.to raise_error(GraphqlDeclarative::Error)
    end

    it "raises for something that is not Base64" do
      expect { described_class.decode("!!!not base64!!!") }
        .to raise_error(GraphqlDeclarative::Error, /malformed cursor/)
    end

    it "raises for Base64 that is not JSON" do
      expect { described_class.decode(Base64.urlsafe_encode64("hello", padding: false)) }
        .to raise_error(GraphqlDeclarative::Error, /malformed cursor/)
    end

    it "raises for JSON that is missing the expected keys" do
      expect { described_class.decode(Base64.urlsafe_encode64('{"offset":3}', padding: false)) }
        .to raise_error(GraphqlDeclarative::Error, /malformed cursor/)
    end

    it "raises for a null id" do
      expect { described_class.decode(Base64.urlsafe_encode64('{"v":"x","i":null}', padding: false)) }
        .to raise_error(GraphqlDeclarative::Error, /missing id/)
    end

    it "does not silently reset to page 1" do
      # Stated as its own expectation because "return nil and start over" is the
      # tempting shortcut and it is the one that hides the bug from the client.
      expect { described_class.decode("garbage") }.to raise_error(GraphqlDeclarative::Error)
    end
  end

  describe ".seek" do
    let!(:rows) do
      [
        Course.create!(title: "A"),
        Course.create!(title: "B"),
        Course.create!(title: "B"),
        Course.create!(title: "C")
      ]
    end

    def seek(column:, direction:, sort_value:, id:)
      scope = GraphqlDeclarative::Sort.apply(
        Course.all, allowed: [:title], field: column, direction: direction
      )
      described_class.seek(scope, column: column, direction: direction, sort_value: sort_value, id: id)
    end

    it "ASC: strictly after the cursor row, tiebreaking on id" do
      after_first_b = seek(column: :title, direction: :asc, sort_value: "B", id: rows[1].id)

      expect(after_first_b.to_a.map(&:id)).to eq([rows[2].id, rows[3].id])
    end

    it "DESC: flips BOTH comparisons" do
      after_second_b = seek(column: :title, direction: :desc, sort_value: "B", id: rows[2].id)

      expect(after_second_b.to_a.map(&:id)).to eq([rows[1].id, rows[0].id])
    end

    it "emits the portable OR form rather than a row-value comparison" do
      sql = seek(column: :title, direction: :asc, sort_value: "B", id: 2).to_sql

      expect(sql).to match(/"courses"\."title" > .+ OR \("courses"\."title" = .+ AND "courses"\."id" > /)
    end

    it "uses < for both halves when descending" do
      sql = seek(column: :title, direction: :desc, sort_value: "B", id: 2).to_sql

      expect(sql).to match(/"courses"\."title" < .+ OR \("courses"\."title" = .+ AND "courses"\."id" < /)
    end

    it "never returns the cursor row itself" do
      after = seek(column: :title, direction: :asc, sort_value: "B", id: rows[1].id)

      expect(after.to_a.map(&:id)).not_to include(rows[1].id)
    end

    it "seeks on :id alone" do
      after = seek(column: :id, direction: :asc, sort_value: rows[1].id, id: rows[1].id)

      expect(after.to_a.map(&:id)).to eq([rows[2].id, rows[3].id])
    end

    it "does not drop rows that share a timestamp to the second" do
      Course.delete_all
      same = Time.utc(2024, 6, 1, 12, 0, 0)
      first = Course.create!(title: "1", created_at: same)
      second = Course.create!(title: "2", created_at: same)

      type = Course.type_for_attribute("created_at")
      cursor = described_class.encode(sort_value: first.reload.created_at, id: first.id)
      payload = described_class.decode(cursor, type: type)

      scope = GraphqlDeclarative::Sort.apply(Course.all, allowed: [:created_at], field: :created_at)
      page = described_class.seek(
        scope, column: :created_at, direction: :asc,
        sort_value: payload[:sort_value], id: payload[:id]
      )

      expect(page.to_a.map(&:id)).to eq([second.id])
    end

    it "raises for an unknown seek column instead of interpolating it" do
      expect {
        described_class.seek(Course.all, column: "id; DROP TABLE courses", direction: :asc, sort_value: 1, id: 1)
      }.to raise_error(GraphqlDeclarative::Error, /no such column/)
    end

    it "raises for a bad direction" do
      expect { described_class.seek(Course.all, column: :id, direction: :sideways, sort_value: 1, id: 1) }
        .to raise_error(GraphqlDeclarative::Error, /direction/)
    end

    it "raises on a NULL sort value instead of silently losing every later row" do
      # SPEC.md §6.4: NULL never compares true. v0.1.0 requires sortable columns
      # to be NOT NULL, and this is where that requirement stops being silent.
      expect { described_class.seek(Course.all, column: :title, direction: :asc, sort_value: nil, id: 1) }
        .to raise_error(GraphqlDeclarative::Error, /NULL/)
    end

    it "passes the seek value as a bind parameter" do
      relation = described_class.seek(
        Course.all, column: :title, direction: :asc, sort_value: "x'; DROP TABLE courses;--", id: 1
      )

      expect(relation.to_a).to eq([])
      expect(Course.count).to eq(4)
    end
  end
end
