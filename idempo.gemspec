# frozen_string_literal: true

require_relative "lib/idempo/version"

Gem::Specification.new do |spec|
  spec.name        = "idempo"
  spec.version     = Idempo::VERSION
  spec.authors     = ["Shailendra Patidar"]
  spec.email       = ["shailendrapatidar00@gmail.com"]

  spec.summary     = "Production-grade idempotency for Rails APIs, background jobs, and webhooks."
  spec.description = <<~DESC
    Idempo provides opt-in idempotency handling for Rails controllers, ActiveJob
    classes, and webhook handlers. It stores idempotency keys in your database,
    fingerprints request payloads to detect misuse, replays cached responses, and
    deduplicates job/webhook execution — all with zero configuration by default.
  DESC
  spec.homepage    = "https://github.com/spatelpatidar/idempo"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata = {
    "homepage_uri"    => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri"   => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }

  # Rails dependency — compatible with Rails 6+
  spec.add_dependency "railties",     ">= 6.0", "< 8.0"
  spec.add_dependency "activerecord", ">= 6.0", "< 8.0"

  # Development / test
  spec.add_development_dependency "rspec",          "~> 3.12"
  spec.add_development_dependency "sqlite3",        "~> 1.6"
  spec.add_development_dependency "activesupport",  ">= 6.0"
  spec.add_development_dependency "activerecord",   ">= 6.0"
  spec.add_development_dependency "rubocop",        "~> 1.60"
  spec.add_development_dependency "rubocop-rails",  "~> 2.23"
  spec.add_development_dependency "rubocop-rspec",  "~> 2.26"
  spec.add_development_dependency "simplecov",      "~> 0.22"
  
  spec.files = Dir.glob("{lib,spec}/**/*", File::FNM_DOTMATCH)
                .reject { |f| File.directory?(f) } +
              %w[idempo.gemspec README.md LICENSE.txt CHANGELOG.md]

  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
