# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Minimal ActiveJob::Base stub so we can test Idempo::Job without Rails
# ---------------------------------------------------------------------------
module ActiveJob
  class Base
    # Provide class_attribute as a no-op that sets a real class-level accessor.
    def self.class_attribute(*attrs, instance_writer: true, **_opts)
      attrs.each do |attr|
        var = :"@_ca_#{attr}"
        define_singleton_method(attr)        { instance_variable_get(var) }
        define_singleton_method(:"#{attr}=") { |v| instance_variable_set(var, v) }
        define_method(attr)                  { self.class.public_send(attr) }
        define_method(:"#{attr}=")           { |v| self.class.public_send(:"#{attr}=", v) } if instance_writer
      end
    end

    def self.prepend(mod); super; end
    def self.name; "ActiveJob::Base"; end
  end
end

# Reload Job module so included do … end fires against our stub
load File.expand_path("../../lib/idempo/job.rb", __FILE__)

RSpec.describe Idempo::Job do
  # ── Helper: build a job class with a given idempotent_by declaration ─────
  def build_job(counter, &configure_block)
    klass = Class.new(ActiveJob::Base) do
      include Idempo::Job
    end
    klass.instance_eval(&configure_block) if configure_block

    # Each anonymous class needs a stable name for key generation
    klass.define_singleton_method(:name) { "TestJob_#{counter.object_id}" }

    # define #perform to increment counter and return order_id
    klass.define_method(:perform) do |**kwargs|
      counter[:count] += 1
      kwargs[:order_id] || kwargs[:user_id] || "done"
    end

    klass
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "first-time execution" do
    it "runs the job and stores the result" do
      counter   = { count: 0 }
      job_class = build_job(counter) { idempotent_by :order_id }

      job_class.new.perform(order_id: "ORD-001")

      expect(counter[:count]).to eq 1
      expect(Idempo::IdempotencyKey.count).to eq 1
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "duplicate prevention (retry safety)" do
    it "executes only once for the same key and returns the cached result" do
      counter   = { count: 0 }
      job_class = build_job(counter) { idempotent_by :order_id }
      instance  = job_class.new

      r1 = instance.perform(order_id: "ORD-002")
      r2 = instance.perform(order_id: "ORD-002")

      expect(counter[:count]).to eq 1
      expect(r1).to eq r2
    end

    it "runs separately for distinct keys" do
      counter   = { count: 0 }
      job_class = build_job(counter) { idempotent_by :order_id }
      instance  = job_class.new

      instance.perform(order_id: "ORD-A")
      instance.perform(order_id: "ORD-B")

      expect(counter[:count]).to eq 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "multi-field key" do
    it "deduplicates on the combination of all declared fields" do
      counter   = { count: 0 }
      job_class = build_job(counter) { idempotent_by :user_id, :email_type }
      job_class.define_method(:perform) do |**kwargs|
        counter[:count] += 1
        "#{kwargs[:user_id]}:#{kwargs[:email_type]}"
      end
      instance = job_class.new

      instance.perform(user_id: 1, email_type: "welcome")
      instance.perform(user_id: 1, email_type: "welcome")   # duplicate → skipped
      instance.perform(user_id: 1, email_type: "reset")     # different combo → runs

      expect(counter[:count]).to eq 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "custom key block" do
    it "uses the block return value as the deduplication key" do
      counter   = { count: 0 }
      job_class = build_job(counter) do
        idempotent_by { |args| "batch:#{args[:batch_id]}:part:#{args[:part]}" }
      end
      job_class.define_method(:perform) do |**kwargs|
        counter[:count] += 1
        kwargs[:batch_id]
      end
      instance = job_class.new

      instance.perform(batch_id: "B1", part: 1)
      instance.perform(batch_id: "B1", part: 1)  # dup → skipped
      instance.perform(batch_id: "B1", part: 2)  # new part → runs

      expect(counter[:count]).to eq 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "opt-out (no idempotent_by declaration)" do
    it "executes every time when no key is declared" do
      counter   = { count: 0 }
      job_class = build_job(counter)  # no idempotent_by
      instance  = job_class.new

      3.times { instance.perform(order_id: "ORD-003") }

      expect(counter[:count]).to eq 3
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  describe "error recovery" do
    it "releases the lock when perform raises so the job can be retried" do
      job_class = Class.new(ActiveJob::Base) do
        include Idempo::Job
        idempotent_by :order_id

        def self.name; "ErrorJob"; end

        def perform(order_id:)
          raise RuntimeError, "payment gateway timeout"
        end
      end

      instance = job_class.new
      expect { instance.perform(order_id: "ORD-FAIL") }
        .to raise_error(RuntimeError, "payment gateway timeout")

      # The lock must be released so the job queue can retry
      expect(Idempo::IdempotencyKey.where("key LIKE 'idempo:job:%'").count).to eq 0
    end
  end
end