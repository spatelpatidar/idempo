# frozen_string_literal: true

require "spec_helper"

RSpec.describe Idempo::Storage::ActiveRecord do
  subject(:store) { described_class.new }

  let(:key)          { "test-#{SecureRandom.uuid}" }
  let(:endpoint)     { "orders#create" }
  let(:request_hash) { Digest::SHA256.hexdigest("application/json:{amount:100}") }

  # ─────────────────────────────────────────────────────────────────────────
  describe "#lock!" do
    it "returns true and creates a locked record on first call" do
      result = store.lock!(key, endpoint: endpoint, request_hash: request_hash)

      expect(result).to be true
      record = Idempo::IdempotencyKey.find_by!(key: key)
      expect(record.locked).to be true
      expect(record.endpoint).to eq endpoint
    end

    it "returns false when the key already exists (race-condition guard)" do
      store.lock!(key, endpoint: endpoint, request_hash: request_hash)
      second_attempt = store.lock!(key, endpoint: endpoint, request_hash: request_hash)

      expect(second_attempt).to be false
      expect(Idempo::IdempotencyKey.where(key: key).count).to eq 1
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "#find" do
    it "returns nil for an unknown key" do
      expect(store.find("ghost-key")).to be_nil
    end

    it "returns the record hash for a known key" do
      store.lock!(key, endpoint: endpoint, request_hash: request_hash)

      result = store.find(key)

      expect(result).to include(
        key:          key,
        endpoint:     endpoint,
        request_hash: request_hash,
        locked:       true
      )
    end

    it "returns nil for an expired record" do
      Idempo::IdempotencyKey.create!(
        key:          key,
        endpoint:     endpoint,
        request_hash: request_hash,
        locked:       false,
        expires_at:   1.hour.ago
      )

      expect(store.find(key)).to be_nil
    end

    it "returns the record when the response has been stored" do
      store.lock!(key, endpoint: endpoint, request_hash: request_hash)
      store.unlock_and_store!(key, response_status: 201, response_body: { "id" => 7 })

      result = store.find(key)

      expect(result[:response_status]).to eq 201
      expect(result[:response_body]).to   eq({ "id" => 7 })
      expect(result[:locked]).to          be false
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "#unlock_and_store!" do
    before { store.lock!(key, endpoint: endpoint, request_hash: request_hash) }

    it "stores the response and clears the lock" do
      store.unlock_and_store!(key, response_status: 200, response_body: { "ok" => true })

      record = Idempo::IdempotencyKey.find_by!(key: key)
      expect(record.locked).to          be false
      expect(record.response_status).to eq 200
      expect(record.response_body).to   eq({ "ok" => true })
    end

    it "does nothing when the key does not exist" do
      expect { store.unlock_and_store!("no-such-key", response_status: 200, response_body: {}) }
        .not_to raise_error
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "#release_lock!" do
    it "deletes the locked record so the operation can be retried" do
      store.lock!(key, endpoint: endpoint, request_hash: request_hash)
      store.release_lock!(key)

      expect(Idempo::IdempotencyKey.find_by(key: key)).to be_nil
    end

    it "is a no-op when the key does not exist" do
      expect { store.release_lock!("ghost") }.not_to raise_error
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "#cleanup_expired!" do
    it "deletes only expired records" do
      Idempo::IdempotencyKey.create!(
        key: "exp-1", endpoint: endpoint, request_hash: request_hash,
        locked: false, expires_at: 2.hours.ago
      )
      Idempo::IdempotencyKey.create!(
        key: "exp-2", endpoint: endpoint, request_hash: request_hash,
        locked: false, expires_at: 30.minutes.ago
      )
      Idempo::IdempotencyKey.create!(
        key: "active-1", endpoint: endpoint, request_hash: request_hash,
        locked: false, expires_at: 1.hour.from_now
      )

      deleted = store.cleanup_expired!

      expect(deleted).to eq 2
      expect(Idempo::IdempotencyKey.pluck(:key)).to contain_exactly("active-1")
    end

    it "returns 0 when nothing has expired" do
      store.lock!(key, endpoint: endpoint, request_hash: request_hash)

      expect(store.cleanup_expired!).to eq 0
    end
  end
end