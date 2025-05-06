# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "standard", "~> 1.3"
# The whole parallel 2.x line requires ruby >= 3.3; 1.x supports >= 2.7. Pinned so the
# standard/rubocop toolchain still installs on the 3.2 CI job.
gem "parallel", "< 2.0"
