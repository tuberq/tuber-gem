# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in tuber.gemspec
gemspec

group :development do
  # 3.5.1 fixes CVE-2020-26298 (XSS when processing quotes). The old '~> 1'
  # pin was inherited from beaneater and capped us below the fix.
  gem 'redcarpet', '~> 3.6', '>= 3.5.1'
  gem 'github-markup'
  gem 'yard'
end

group :development, :test do
  gem 'coveralls', :require => false
end
