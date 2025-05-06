# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Sort.apply (SPEC.md §6.3).
#
# Two properties, both load-bearing for pagination rather than for tidiness:
#
# 1. The whitelist. A column name never travels from the client into SQL; the
#    name that reaches ActiveRecord is the one the declaration supplied.
#
# 2. The :id tiebreaker, always appended, always in the same direction. Without
#    it the order is not total: two rows with the same title can come back in
#    either order between requests, and a keyset cursor built from (title, id)
#    cannot tell them apart — page 2 then repeats or skips the tied rows.
# ---------------------------------------------------------------------------

RSpec.describe GraphqlDeclarative::Sort do
  let(:allowed) { %i[title created_at] }

  describe "whitelist enforcement" do
    it "orders by a whitelisted field" do
      sql = described_class.apply(Course.all, allowed: allowed, field: :title).to_sql

      expect(sql).to match(/ORDER BY "courses"\."title" ASC/)
    end

    it "raises for a field that is not whitelisted" do
      expect { described_class.apply(Course.all, allowed: allowed, field: :published) }
        .to raise_error(GraphqlDeclarative::Error, /"published" is not sortable/)
    end

    it "raises for an outright injection attempt instead of interpolating it" do
      expect {
        described_class.apply(Course.all, allowed: allowed, field: "title; DROP TABLE courses")
      }.to raise_error(GraphqlDeclarative::Error, /is not sortable/)
    end

    it "uses the whitelist's own canonical name, not the caller's string" do
      # A GraphQL enum may arrive as "CREATED_AT"; what reaches ActiveRecord is
      # the declared :created_at.
      sql = described_class.apply(Course.all, allowed: allowed, field: "CREATED_AT").to_sql

      expect(sql).to match(/ORDER BY "courses"\."created_at" ASC/)
    end

    it "treats :id as implicitly sortable even when not declared" do
      sql = described_class.apply(Course.all, allowed: allowed, field: :id).to_sql

      expect(sql).to match(/ORDER BY "courses"\."id" ASC/)
    end

    it "falls back to :id when no field is requested" do
      sql = described_class.apply(Course.all, allowed: allowed, field: nil).to_sql

      expect(sql).to match(/ORDER BY "courses"\."id" ASC\z/)
    end

    it "falls back to :id when nothing is whitelisted at all" do
      sql = described_class.apply(Course.all, allowed: [], field: nil).to_sql

      expect(sql).to match(/ORDER BY "courses"\."id" ASC\z/)
    end

    it "raises when a whitelisted name is not a column on the model" do
      expect { described_class.apply(Course.all, allowed: [:nonexistent], field: :nonexistent) }
        .to raise_error(GraphqlDeclarative::Error, /has no such column/)
    end

    it "refuses to sort on a through: column rather than silently joining" do
      # A join multiplies rows — the exact corruption in
      # spec/pagination_through_associations_spec.rb. Out of scope for v0.1.0,
      # so it is an error, not a surprise.
      definition = GraphqlDeclarative::FilterInput::Definition.new(
        name: :author_name, type: :string, ops: [:eq], through: :author, column: :name
      )

      expect { described_class.apply(Course.all, allowed: [definition], field: :author_name) }
        .to raise_error(GraphqlDeclarative::Error, /through: :author/)
    end
  end

  describe ":id tiebreaker" do
    it "appends :id after the sort column" do
      sql = described_class.apply(Course.all, allowed: allowed, field: :title).to_sql

      expect(sql).to match(/ORDER BY "courses"\."title" ASC, "courses"\."id" ASC\z/)
    end

    it "appends :id in the SAME direction as the sort column" do
      sql = described_class.apply(Course.all, allowed: allowed, field: :title, direction: :desc).to_sql

      expect(sql).to match(/ORDER BY "courses"\."title" DESC, "courses"\."id" DESC\z/)
    end

    it "does not append :id twice when sorting by :id" do
      sql = described_class.apply(Course.all, allowed: allowed, field: :id).to_sql

      expect(sql.scan('"courses"."id"').size).to eq(1)
    end

    it "makes the order total across tied sort values" do
      a = Course.create!(title: "Same")
      b = Course.create!(title: "Same")
      c = Course.create!(title: "Same")

      ordered = described_class.apply(Course.all, allowed: allowed, field: :title).to_a

      expect(ordered.map(&:id)).to eq([a.id, b.id, c.id])
    end

    it "reverses the tied rows too when the direction flips" do
      a = Course.create!(title: "Same")
      b = Course.create!(title: "Same")

      ordered = described_class.apply(Course.all, allowed: allowed, field: :title, direction: :desc).to_a

      expect(ordered.map(&:id)).to eq([b.id, a.id])
    end
  end

  describe "direction" do
    let!(:beta) { Course.create!(title: "Beta") }
    let!(:alpha) { Course.create!(title: "Alpha") }

    it "defaults to ascending" do
      expect(described_class.apply(Course.all, allowed: allowed, field: :title).to_a).to eq([alpha, beta])
    end

    it "accepts :desc" do
      expect(described_class.apply(Course.all, allowed: allowed, field: :title, direction: :desc).to_a)
        .to eq([beta, alpha])
    end

    it "accepts a string, and is case-insensitive" do
      expect(described_class.apply(Course.all, allowed: allowed, field: :title, direction: "DESC").to_a)
        .to eq([beta, alpha])
    end

    it "raises for anything else" do
      expect { described_class.apply(Course.all, allowed: allowed, field: :title, direction: :sideways) }
        .to raise_error(GraphqlDeclarative::Error, /sort direction must be/)
    end
  end

  describe "replacing an existing order" do
    it "reorders rather than appending, so the declared sort leads" do
      # The seek predicate is built from OUR leading term. Appending to someone
      # else's ORDER BY would leave a different column leading and the cursor
      # would compare the wrong thing.
      sql = described_class.apply(Course.order(:created_at), allowed: allowed, field: :title).to_sql

      expect(sql).to match(/ORDER BY "courses"\."title" ASC, "courses"\."id" ASC\z/)
    end
  end

  describe ".column_for" do
    it "reports the column that will actually be ordered by" do
      expect(described_class.column_for(Course.all, allowed: allowed, field: "TITLE")).to eq(:title)
    end

    it "reports :id when no field was requested" do
      expect(described_class.column_for(Course.all, allowed: allowed, field: nil)).to eq(:id)
    end

    it "raises on an unsortable field, same as .apply" do
      expect { described_class.column_for(Course.all, allowed: allowed, field: :published) }
        .to raise_error(GraphqlDeclarative::Error)
    end
  end
end
