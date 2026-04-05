# frozen_string_literal: true

require "spec_helper"

RSpec.describe Idempo::Configuration do
  subject(:config) { described_class.new }

  # ─────────────────────────────────────────────────────────────────────────
  describe "defaults" do
    it "sets expiry to 24 hours in seconds" do
      expect(config.expiry).to eq(24 * 60 * 60)
    end

    it "enforces payload matching by default" do
      expect(config.enforce_payload_match).to be true
    end

    it "stores responses by default" do
      expect(config.store_response).to be true
    end

    it "uses an ActiveRecord store by default" do
      expect(config.store).to be_a(Idempo::Storage::ActiveRecord)
    end

    it "has no Redis client configured by default" do
      expect(config.redis).to be_nil
    end

    it "treats all 5xx status codes as non-cacheable" do
      expect(config.non_cacheable_statuses).to include(500, 502, 503, 504)
      expect(config.non_cacheable_statuses).not_to include(200, 201, 422, 409)
    end

    it "limits keys to 255 characters" do
      expect(config.max_key_length).to eq 255
    end

    it "provides a logger" do
      expect(config.logger).to respond_to(:info, :warn, :error, :debug)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "mutability" do
    it "allows overriding expiry" do
      config.expiry = 1800
      expect(config.expiry).to eq 1800
    end

    it "allows disabling payload enforcement" do
      config.enforce_payload_match = false
      expect(config.enforce_payload_match).to be false
    end

    it "allows disabling response storage" do
      config.store_response = false
      expect(config.store_response).to be false
    end

    it "allows supplying a custom store" do
      fake_store = double("Store")
      config.store = fake_store
      expect(config.store).to be(fake_store)
    end

    it "allows supplying a Redis client" do
      fake_redis = double("Redis")
      config.redis = fake_redis
      expect(config.redis).to be(fake_redis)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "Idempo.configure" do
    it "yields the shared configuration instance" do
      yielded = nil
      Idempo.configure { |c| yielded = c }
      expect(yielded).to be(Idempo.configuration)
    end

    it "applies changes to the live configuration" do
      Idempo.configure do |c|
        c.expiry                = 7200
        c.enforce_payload_match = false
      end

      expect(Idempo.configuration.expiry).to               eq 7200
      expect(Idempo.configuration.enforce_payload_match).to be false
    end
  end
end