# frozen_string_literal: true

require "spec_helper"

# Reload Webhook module so included do … end picks up the test environment
load File.expand_path("../../lib/idempo/webhook.rb", __FILE__)

RSpec.describe Idempo::Webhook do
  # ── Helper: build a handler class ─────────────────────────────────────────
  def build_handler(call_log, name_suffix = SecureRandom.hex(4), &configure_block)
    klass = Class.new do
      # Provide class_attribute for include Idempo::Webhook
      def self.class_attribute(*attrs, instance_writer: true, **_opts)
        attrs.each do |attr|
          var = :"@_ca_#{attr}"
          define_singleton_method(attr)        { instance_variable_get(var) }
          define_singleton_method(:"#{attr}=") { |v| instance_variable_set(var, v) }
          define_method(attr)                  { self.class.public_send(attr) }
        end
      end

      def self.prepend(mod); super; end
    end

    klass.define_singleton_method(:name) { "WebhookHandler_#{name_suffix}" }

    klass.include Idempo::Webhook
    klass.instance_eval(&configure_block) if configure_block

    klass.define_method(:process) do |**kwargs|
      call_log << kwargs.dup
      "processed:#{kwargs[:event_id] || kwargs.values.first}"
    end

    klass
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "first-time event processing" do
    it "processes the event and records it" do
      log          = []
      handler_class = build_handler(log) { idempotent_by :event_id }

      handler_class.new.process(event_id: "evt_001", type: "charge.created")

      expect(log.size).to eq 1
      expect(Idempo::IdempotencyKey.count).to eq 1
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "duplicate event deduplication" do
    it "processes a given event_id only once" do
      log          = []
      handler_class = build_handler(log) { idempotent_by :event_id }
      handler       = handler_class.new

      handler.process(event_id: "evt_dup", type: "charge.succeeded")
      handler.process(event_id: "evt_dup", type: "charge.succeeded")

      expect(log.size).to eq 1
    end

    it "returns the same result on the second call" do
      log          = []
      handler_class = build_handler(log) { idempotent_by :event_id }
      handler       = handler_class.new

      r1 = handler.process(event_id: "evt_x")
      r2 = handler.process(event_id: "evt_x")

      expect(r1).to eq "processed:evt_x"
      expect(r2).to eq "processed:evt_x"
    end

    it "processes different event IDs independently" do
      log          = []
      handler_class = build_handler(log) { idempotent_by :event_id }
      handler       = handler_class.new

      handler.process(event_id: "evt_001")
      handler.process(event_id: "evt_002")

      expect(log.size).to eq 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "source namespacing" do
    it "isolates keys by source so identical event IDs from different providers don't collide" do
      stripe_log = []
      paypal_log = []

      stripe_class = build_handler(stripe_log, "stripe") { idempotent_by :event_id, source: "stripe" }
      paypal_class = build_handler(paypal_log, "paypal") { idempotent_by :event_id, source: "paypal" }

      stripe_class.new.process(event_id: "EVT-999")
      paypal_class.new.process(event_id: "EVT-999")   # same event_id, different source

      expect(stripe_log.size).to eq 1
      expect(paypal_log.size).to eq 1
      expect(Idempo::IdempotencyKey.count).to eq 2    # two distinct keys in DB
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "custom key block" do
    it "uses the block return value as the deduplication key" do
      log          = []
      handler_class = build_handler(log) do
        idempotent_by { |args| "#{args[:repo]}:#{args[:delivery]}" }
      end
      handler = handler_class.new

      handler.process(repo: "acme/app", delivery: "D1")
      handler.process(repo: "acme/app", delivery: "D1")  # dup → skipped
      handler.process(repo: "acme/app", delivery: "D2")  # new delivery → runs

      expect(log.size).to eq 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "opt-out (no idempotent_by declaration)" do
    it "processes every call when no key is declared" do
      log          = []
      handler_class = build_handler(log)  # no idempotent_by
      handler       = handler_class.new

      3.times { handler.process(event_id: "evt_always") }

      expect(log.size).to eq 3
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "error recovery" do
    it "releases the lock when process raises so the event can be retried" do
      klass = Class.new do
        def self.class_attribute(*attrs, instance_writer: true, **_opts)
          attrs.each do |attr|
            var = :"@_ca_#{attr}"
            define_singleton_method(attr)        { instance_variable_get(var) }
            define_singleton_method(:"#{attr}=") { |v| instance_variable_set(var, v) }
            define_method(attr)                  { self.class.public_send(attr) }
          end
        end
        def self.prepend(mod); super; end
        def self.name; "ErrorHandler"; end
      end

      klass.include Idempo::Webhook
      klass.idempotent_by :event_id
      klass.define_method(:process) { |**_| raise "downstream failure" }

      expect { klass.new.process(event_id: "bad_evt") }
        .to raise_error("downstream failure")

      # Lock must be released so the message queue can redeliver
      expect(Idempo::IdempotencyKey.where("key LIKE 'idempo:webhook:%'").count).to eq 0
    end
  end
end