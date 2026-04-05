# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Idempo::Fingerprint do
  # ── Minimal Rack-compatible request stub ───────────────────────────────────
  def stub_request(body:, content_type: "application/json", method: "POST", path: "/orders")
    body_io = StringIO.new(body)
    OpenStruct.new(
      request_method: method,
      fullpath:        path,
      content_type:    content_type,
      body:            body_io
    )
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe ".for_request" do
    it "returns a 64-character hex string" do
      req = stub_request(body: '{"amount":100}')
      expect(described_class.for_request(req)).to match(/\A[0-9a-f]{64}\z/)
    end

    it "produces the same fingerprint for identical requests" do
      body = '{"amount":100,"currency":"usd"}'
      r1   = stub_request(body: body)
      r2   = stub_request(body: body)
      expect(described_class.for_request(r1)).to eq described_class.for_request(r2)
    end

    it "produces the same fingerprint regardless of JSON key order" do
      r1 = stub_request(body: '{"b":2,"a":1}')
      r2 = stub_request(body: '{"a":1,"b":2}')
      expect(described_class.for_request(r1)).to eq described_class.for_request(r2)
    end

    it "produces different fingerprints for different bodies" do
      r1 = stub_request(body: '{"amount":100}')
      r2 = stub_request(body: '{"amount":200}')
      expect(described_class.for_request(r1)).not_to eq described_class.for_request(r2)
    end

    it "produces different fingerprints for different paths" do
      r1 = stub_request(body: '{}', path: "/orders")
      r2 = stub_request(body: '{}', path: "/payments")
      expect(described_class.for_request(r1)).not_to eq described_class.for_request(r2)
    end

    it "handles non-JSON content types without raising" do
      req = stub_request(body: "plain text body", content_type: "text/plain")
      expect { described_class.for_request(req) }.not_to raise_error
    end

    it "handles an empty body" do
      req = stub_request(body: "")
      expect(described_class.for_request(req)).to match(/\A[0-9a-f]{64}\z/)
    end

    it "rewinds the IO so subsequent reads see the full body" do
      req = stub_request(body: '{"x":1}')
      described_class.for_request(req)
      req.body.rewind
      expect(req.body.read).to eq '{"x":1}'
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe ".for_attributes" do
    it "returns a 64-character hex string" do
      expect(described_class.for_attributes(order_id: "ORD-1")).to match(/\A[0-9a-f]{64}\z/)
    end

    it "is stable across calls" do
      a1 = described_class.for_attributes(order_id: "ORD-1", amount: 500)
      a2 = described_class.for_attributes(order_id: "ORD-1", amount: 500)
      expect(a1).to eq a2
    end

    it "differs for different attribute values" do
      a1 = described_class.for_attributes(order_id: "ORD-1")
      a2 = described_class.for_attributes(order_id: "ORD-2")
      expect(a1).not_to eq a2
    end
  end
end