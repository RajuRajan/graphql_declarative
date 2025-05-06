# frozen_string_literal: true

require "active_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = nil

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :authors, force: true do |t|
    t.string :name
    t.timestamps
  end

  create_table :courses, force: true do |t|
    t.string :title, null: false
    t.boolean :published, default: false
    t.references :author
    t.timestamps
  end

  create_table :enrollments, force: true do |t|
    t.references :course
    t.string :status          # "active" | "cancelled"
    t.timestamps
  end

  # Nullable sortable column, on purpose — SPEC.md §6.4/§6.3 require
  # `sortable_by` columns to be NOT NULL and Sort.apply must raise rather than
  # let rows with a NULL sort value silently vanish mid-pagination. `subtitle`
  # is deliberately left nullable so sort_spec.rb can exercise that raise
  # against a real column, not a mocked one.
  create_table :articles, force: true do |t|
    t.string :title, null: false
    t.string :subtitle # nullable: this is the point of the fixture
    t.timestamps
  end

  # Non-`id` primary key, on purpose — SPEC.md §6.3/§6.4 require Sort's ORDER
  # BY tiebreaker and Cursor's seek predicate to agree on `model.primary_key`,
  # whatever it is named. `id: false` + a `uuid` primary key is the minimal
  # fixture that would break a hardcoded `:id` tiebreaker.
  create_table :widgets, id: false, force: true do |t|
    t.string :uuid, null: false
    t.string :name, null: false
  end
end

class Author < ActiveRecord::Base
  has_many :courses
end

class Course < ActiveRecord::Base
  belongs_to :author, optional: true
  has_many :enrollments
end

class Enrollment < ActiveRecord::Base
  belongs_to :course
end

class Article < ActiveRecord::Base
end

class Widget < ActiveRecord::Base
  self.primary_key = "uuid"
end
