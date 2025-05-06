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
    t.string :title
    t.boolean :published, default: false
    t.references :author
    t.timestamps
  end

  create_table :enrollments, force: true do |t|
    t.references :course
    t.string :status          # "active" | "cancelled"
    t.timestamps
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
