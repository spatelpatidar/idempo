# frozen_string_literal: true

require "spec_helper"

RSpec.describe Idempo::PayloadMismatchError do
  subject(:error) { described_class.new("order-key-abc") }

  it "is a subclass of Idempo::Error" do
    expect(error).to be_a(Idempo::Error)
  end

  it "exposes the offending idempotency key" do
    expect(error.idempotency_key).to eq "order-key-abc"
  end

  it "includes the key in the message" do
    expect(error.message).to include("order-key-abc")
  end

  it "describes the payload mismatch cause" do
    expect(error.message).to match(/different.*payload/i)
  end
end

RSpec.describe Idempo::ConcurrentRequestError do
  subject(:error) { described_class.new("concurrent-key-xyz") }

  it "is a subclass of Idempo::Error" do
    expect(error).to be_a(Idempo::Error)
  end

  it "includes the key in the message" do
    expect(error.message).to include("concurrent-key-xyz")
  end
end

RSpec.describe Idempo::InvalidKeyError do
  it "is a subclass of Idempo::Error" do
    expect(described_class.new("bad key")).to be_a(Idempo::Error)
  end

  it "can carry a descriptive message" do
    err = described_class.new("Key exceeds 255 characters")
    expect(err.message).to include("255")
  end
end