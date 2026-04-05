# frozen_string_literal: true

module Idempo
  # ActiveJob mixin that prevents duplicate job execution across retries.
  #
  # @example Deduplicate by a single argument
  #   class ChargeOrderJob < ApplicationJob
  #     include Idempo::Job
  #     idempotent_by :order_id
  #
  #     def perform(order_id:, amount:)
  #       Order.find(order_id).charge!(amount)
  #     end
  #   end
  #
  # @example Deduplicate by multiple arguments
  #   class SendEmailJob < ApplicationJob
  #     include Idempo::Job
  #     idempotent_by :user_id, :email_type
  #
  #     def perform(user_id:, email_type:, locale: "en")
  #       User.find(user_id).send_email(email_type, locale: locale)
  #     end
  #   end
  #
  # @example Custom key via block
  #   class ImportJob < ApplicationJob
  #     include Idempo::Job
  #     idempotent_by { |args| "import-#{args[:import_id]}-#{args[:batch]}" }
  #   end
  module Job
    extend ActiveSupport::Concern

    JOB_KEY_PREFIX = "idempo:job:"

    included do
      class_attribute :_idempo_job_key_fields, instance_writer: false
      class_attribute :_idempo_job_key_block,  instance_writer: false

      self._idempo_job_key_fields = []
      self._idempo_job_key_block  = nil

      prepend PerformWrapper
    end

    class_methods do
      # Declares the deduplication strategy for this job class.
      #
      # @param fields [Array<Symbol>] keyword argument names used as the key
      # @param block  [Proc]         receives the arguments, must return a String
      def idempotent_by(*fields, &block)
        self._idempo_job_key_fields = fields.map(&:to_sym)
        self._idempo_job_key_block  = block
      end
    end

    # Wraps +perform+ to inject idempotency before the real work begins.
    module PerformWrapper
      def perform(*args, **kwargs)
        key_fields = self.class._idempo_job_key_fields
        key_block  = self.class._idempo_job_key_block

        return super(*args, **kwargs) if key_fields.blank? && key_block.nil?

        idempo_key = compute_job_key(args, kwargs, key_fields, key_block)

        existing = Idempo.store.find(idempo_key)
        if existing && !existing[:locked] && existing[:response_body].present?
          Idempo.logger.info("[Idempo] Job HIT — skipping duplicate. key=#{idempo_key}")
          return existing.dig(:response_body, "result")
        end

        locked = Idempo.store.lock!(idempo_key, endpoint: self.class.name, request_hash: idempo_key)

        unless locked
          Idempo.logger.warn("[Idempo] Job LOCKED key=#{idempo_key}")
          existing = Idempo.store.find(idempo_key)
          return existing.dig(:response_body, "result") if existing&.dig(:response_body).present?
        end

        Idempo.logger.info("[Idempo] Job MISS — executing. key=#{idempo_key}")
        result = super(*args, **kwargs)

        Idempo.store.unlock_and_store!(
          idempo_key,
          response_status: 200,
          response_body:   { "result" => safe_serialize(result) },
        )

        result
      rescue StandardError
        Idempo.store.release_lock!(idempo_key) rescue nil # rubocop:disable Style/RescueModifier
        raise
      end

      private

      def compute_job_key(args, kwargs, key_fields, key_block)
        raw = if key_block
          key_block.call(kwargs.empty? ? args.first : kwargs)
        else
          values = key_fields.map { |f| kwargs[f] || kwargs[f.to_s] }.compact
          "#{self.class.name}:#{values.join(":")}"
        end

        JOB_KEY_PREFIX + Digest::SHA256.hexdigest(raw.to_s)
      end

      def safe_serialize(value)
        value.respond_to?(:as_json) ? value.as_json : value.to_s
      rescue StandardError
        value.to_s
      end
    end
  end
end