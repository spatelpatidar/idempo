# frozen_string_literal: true

# ── Gempath bootstrap (run via: bundle exec rspec) ─────────────────────────────
require "active_support/all"
require "active_record"
require "digest"
require "json"
require "logger"

# ── In-memory SQLite database ──────────────────────────────────────────────────
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = nil  # suppress SQL noise

ActiveRecord::Schema.define do
  create_table :idempotency_keys, force: true do |t|
    t.string   :key,             null: false, limit: 255
    t.string   :endpoint,        null: false, limit: 255
    t.string   :request_hash,    null: false, limit: 64
    # SQLite has no jsonb; we serialize manually via `serialize :response_body`
    t.text     :response_body
    t.integer  :response_status
    t.boolean  :locked,          null: false, default: false
    t.datetime :expires_at,      null: false
    t.timestamps null: false
  end
  add_index :idempotency_keys, :key, unique: true
end

# ── Load Idempo library files ──────────────────────────────────────────────────
require_relative "../lib/idempo/version"
require_relative "../lib/idempo/errors"
require_relative "../lib/idempo/fingerprint"
require_relative "../lib/idempo/configuration"
require_relative "../lib/idempo/storage/active_record"
require_relative "../lib/idempo/job"
require_relative "../lib/idempo/webhook"
require_relative "../lib/idempo"

# ── ActiveRecord model (test-only) ────────────────────────────────────────────
# The real model lives in lib/idempo/models/idempotency_key.rb and is loaded
# by the Railtie in a real Rails app. We define it inline here for test isolation.
module Idempo
  class IdempotencyKey < ActiveRecord::Base
    self.table_name = "idempotency_keys"
    serialize :response_body, coder: JSON
    validates :key,      presence: true, uniqueness: true
    validates :endpoint, presence: true
  end
end

# ── Patch ActiveRecord storage for SQLite test compatibility ──────────────────
# SQLite's INSERT … ON CONFLICT support is limited before SQLite 3.35.
# We replace upsert and lock! with simpler equivalents that work on any SQLite version.
module Idempo
  module Storage
    class ActiveRecord
      def upsert(attrs)
        expires_at = Time.current + Idempo.configuration.expiry
        now        = Time.current

        record = model.find_or_initialize_by(key: attrs[:key])
        record.assign_attributes(attrs.merge(expires_at: expires_at, updated_at: now))
        record.created_at = now if record.new_record?
        record.save!
        find(attrs[:key])
      end

      def lock!(key, endpoint:, request_hash:)
        now = Time.current
        model.create!(
          key:          key,
          endpoint:     endpoint,
          request_hash: request_hash,
          locked:       true,
          expires_at:   now + Idempo.configuration.expiry,
          created_at:   now,
          updated_at:   now
        )
        true
      rescue ::ActiveRecord::RecordNotUnique, ::ActiveRecord::RecordInvalid
        false
      end
    end
  end
end

# ── RSpec configuration ────────────────────────────────────────────────────────
RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.include_chain_clauses_in_custom_matcher_descriptions = true }
  config.mock_with(:rspec)   { |c| c.verify_partial_doubles = true }
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = false
  config.order    = :random
  Kernel.srand config.seed

  config.before(:each) do
    Idempo::IdempotencyKey.delete_all
    Idempo.reset!
    Idempo.configure do |c|
      c.expiry                 = 3600
      c.enforce_payload_match  = true
      c.store_response         = true
      c.store                  = Idempo::Storage::ActiveRecord.new
      c.logger                 = Logger.new(nil)   # silence during tests
      c.non_cacheable_statuses = (500..599).to_a
      c.max_key_length         = 255
    end
  end
end
