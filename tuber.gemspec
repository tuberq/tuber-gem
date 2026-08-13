# frozen_string_literal: true
# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'tuber/version'

Gem::Specification.new do |gem|
  gem.name          = "tuber"
  gem.version       = Tuber::VERSION
  gem.authors       = ["Dan Milne", "Nico Taing"]
  gem.email         = ["d@nmilne.com"]
  gem.description   = %q{Ruby client for Tuber and beanstalkd job queues. A fork of beaneater with support for Tuber's protocol extensions.}
  gem.summary       = %q{Ruby client for Tuber and beanstalkd.}
  gem.homepage      = "https://github.com/tuberq/tuber-gem"
  gem.license       = 'MIT'

  gem.required_ruby_version = '>= 2.7.0'

  gem.metadata = {
    'source_code_uri'   => gem.homepage,
    'changelog_uri'     => "#{gem.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri'   => "#{gem.homepage}/issues",
  }

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.require_paths = ["lib"]
  gem.add_development_dependency 'minitest', "~> 4.1.0"
  gem.add_development_dependency 'rake'
  gem.add_development_dependency 'mocha'
  gem.add_development_dependency 'term-ansicolor'
  gem.add_development_dependency 'json'
end
