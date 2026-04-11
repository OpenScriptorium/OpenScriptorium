source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# === Open Scriptorium project gems ===
# All gems below are FOSS-licensed (MIT, BSD, Apache 2.0, MPL, or LGPL).
# No open-core gems with proprietary "pro" tiers. See CLAUDE.md.

# CommonMark renderer (libcmark-gfm bindings) for annotation/note rendering.
# License: MIT. https://github.com/gjtorikian/commonmarker
gem "commonmarker", "~> 2.3"

# Postgres full-text search via pg_search gem (uses tsvector + GIN).
# License: MIT. https://github.com/Casecommons/pg_search
gem "pg_search", "~> 2.3"

# PaperTrail tracks model changes for the moderation/wiki workflow.
# License: MIT. https://github.com/paper-trail-gem/paper_trail
gem "paper_trail", "~> 17.0"

# `csv` is no longer a default gem in Ruby 3.4+. Importers parse a lot
# of CSV files. License: BSD-2-Clause. https://github.com/ruby/csv
gem "csv"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Capistrano for deploys to the Toronto VPS via SSH. All MIT-licensed.
  # Runs only on the local machine; never installed on the server.
  # See config/deploy.rb and config/deploy/production.rb.
  gem "capistrano",         "~> 3.19", require: false
  gem "capistrano-rails",   "~> 1.7",  require: false
  gem "capistrano-bundler", "~> 2.1",  require: false
  gem "capistrano-rbenv",   "~> 2.2",  require: false
  gem "capistrano3-puma",   "~> 6.0",  require: false
end

# SQLite for bulk export downloads
gem "sqlite3"

# Rate limiting
gem "rack-attack"

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end
