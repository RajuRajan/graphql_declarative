# frozen_string_literal: true

# Reproducible query-count benchmark backing the numbers in README.md.
#   ruby bench/query_count.rb
#
# Measures the SQL a page costs with and without selection-set-driven preloading,
# counting real statements via ActiveSupport::Notifications.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "graphql_declarative"
require "active_record"
require "benchmark"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = nil
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:authors) { |t| t.string :name, null: false }
  create_table :courses do |t|
    t.string :title, null: false
    t.references :author
  end
  create_table :enrollments do |t|
    t.references :course
    t.string :status
  end
end

class Author < ActiveRecord::Base; has_many :courses; end
class Enrollment < ActiveRecord::Base; belongs_to :course; end

class Course < ActiveRecord::Base
  belongs_to :author, optional: true
  has_many :enrollments
end

AUTHORS = 200
COURSES = 2_000
PAGE = 25

authors = Array.new(AUTHORS) { |i| Author.create!(name: "Author #{i}") }
COURSES.times do |i|
  c = Course.create!(title: format("Course %05d", i), author: authors[i % AUTHORS])
  3.times { |j| c.enrollments.create!(status: j.zero? ? "active" : "cancelled") }
end

def count_queries
  n = 0
  sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
    n += 1 unless /SCHEMA|TRANSACTION/.match?(payload[:name].to_s)
  end
  yield
  n
ensure
  ActiveSupport::Notifications.unsubscribe(sub)
end

def touch(courses)
  courses.each do |c|
    c.author&.name
    c.enrollments.map(&:status)
  end
end

scope = Course.where(id: Course.joins(:enrollments).where(enrollments: {status: "active"}).select(:id))

puts "#{COURSES} courses / #{AUTHORS} authors / #{COURSES * 3} enrollments, page of #{PAGE}"
puts "query is: courses(first: #{PAGE}) { author { name } enrollments { status } }"
puts

[["no preloading (the N+1 baseline)", -> { touch(scope.order(:id).limit(PAGE).to_a) }],
  ["preload derived from the selection set", -> { touch(scope.order(:id).limit(PAGE).preload(:author, :enrollments).to_a) }]].each do |label, run|
  run.call # warm
  queries = count_queries { run.call }
  ms = Benchmark.realtime { 5.times { run.call } } / 5 * 1000
  puts format("  %-40s %4d queries   %6.1f ms", label, queries, ms)
end
