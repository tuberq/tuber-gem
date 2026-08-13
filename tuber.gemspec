Gem::Specification.new do |s|
  s.name        = "tuber"
  s.version     = "0.0.1"
  s.summary     = "Ruby client for the Tuber job queue server"
  s.description = "Ruby client for Tuber, a fast beanstalkd-compatible job queue server. This release reserves the gem name; use the russet gem for a full-featured client in the meantime."
  s.authors     = ["Dan Milne"]
  s.email       = ["d@nmilne.com"]
  s.homepage    = "https://github.com/tuberq/tuber-gem"
  s.license     = "MIT"

  s.required_ruby_version = ">= 2.7.0"

  s.metadata = {
    "source_code_uri" => s.homepage,
    "bug_tracker_uri" => "#{s.homepage}/issues",
  }

  s.files         = ["README.md", "lib/tuber.rb"]
  s.require_paths = ["lib"]
end
