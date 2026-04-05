# frozen_string_literal: true

require "spec_helper"

RSpec.describe Idempo do
  # ─────────────────────────────────────────────────────────────────────────
  describe ".configure / .configuration" do
    it "yields the configuration object" do
      Idempo.configure { |c| c.expiry = 7200 }
      expect(Idempo.configuration.expiry).to eq 7200
    end

    it "returns the same configuration object on repeated calls" do
      first  = Idempo.configuration
      second = Idempo.configuration
      expect(first).to be(second)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe ".store" do
    it "returns the store set in configuration" do
      expect(Idempo.store).to be(Idempo.configuration.store)
    end

    it "returns an ActiveRecord store by default" do
      expect(Idempo.store).to be_a(Idempo::Storage::ActiveRecord)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe ".logger" do
    it "returns a Logger instance" do
      expect(Idempo.logger).to be_a(Logger)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe ".cleanup_expired!" do
    it "delegates to the configured store and returns the count" do
      store = instance_double(Idempo::Storage::ActiveRecord, cleanup_expired!: 5)
      Idempo.configuration.store = store

      result = Idempo.cleanup_expired!

      expect(result).to eq 5
      expect(store).to have_received(:cleanup_expired!)
    end

    it "removes expired records through the real store" do
      Idempo::IdempotencyKey.create!(
        key:          "stale",
        endpoint:     "orders#create",
        request_hash: "abc",
        locked:       false,
        expires_at:   1.day.ago
      )
      Idempo::IdempotencyKey.create!(
        key:          "fresh",
        endpoint:     "orders#create",
        request_hash: "def",
        locked:       false,
        expires_at:   1.day.from_now
      )

      deleted = Idempo.cleanup_expired!

      expect(deleted).to eq 1
      expect(Idempo::IdempotencyKey.pluck(:key)).to eq ["fresh"]
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe ".reset!" do
    it "clears the memoized configuration" do
      original = Idempo.configuration
      Idempo.reset!
      expect(Idempo.configuration).not_to be(original)
    end
  end
end
