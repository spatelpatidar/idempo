# frozen_string_literal: true

module Idempo
  # Mixin for webhook handler classes that prevents duplicate event processing.
  #
  # @example Basic usage with Stripe
  #   class StripeWebhookHandler
  #     include Idempo::Webhook
  #     idempotent_by :event_id
  #
  #     def process(event_id:, type:, data:)
  #       Order.find(data[:order_id]).charge! if type == "charge.succeeded"
  #     end
  #   end
  #
  # @example Source-namespaced (avoids key collisions between providers)
  #   class PaypalWebhookHandler
  #     include Idempo::Webhook
  #     idempotent_by :transmission_id, source: "paypal"
  #   end
  #
  # @example Custom key block
  #   class GithubWebhookHandler
  #     include Idempo::Webhook
  #     idempotent_by { |args| "#{args[:repository]}:#{args[:delivery_id]}" }
  #   end
  module Webhook
    extend ActiveSupport::Concern

    WEBHOOK_KEY_PREFIX = "idempo:webhook:"

    included do
      class_attribute :_idempo_webhook_key_fields, instance_writer: false
      class_attribute :_idempo_webhook_key_block,  instance_writer: false
      class_attribute :_idempo_webhook_source,     instance_writer: false

      self._idempo_webhook_key_fields = []
      self._idempo_webhook_key_block  = nil
      self._idempo_webhook_source     = nil

      prepend ProcessWrapper
    end

    class_methods do
      # Declares the deduplication key for incoming webhook events.
      #
      # @param fields [Array<Symbol>] keyword argument names to use as the key
      # @param source [String, nil]  optional namespace (e.g. "stripe", "github")
      # @param block  [Proc]         receives the arguments, must return a String
      def idempotent_by(*fields, source: nil, &block)
        self._idempo_webhook_key_fields = fields.map(&:to_sym)
        self._idempo_webhook_key_block  = block
        self._idempo_webhook_source     = source
      end
    end

    # Wraps +process+ to inject deduplication before the real handler runs.
    module ProcessWrapper
      def process(*args, **kwargs)
        key_fields = self.class._idempo_webhook_key_fields
        key_block  = self.class._idempo_webhook_key_block

        return super(*args, **kwargs) if key_fields.blank? && key_block.nil?

        idempo_key = compute_webhook_key(args, kwargs, key_fields, key_block)

        existing = Idempo.store.find(idempo_key)
        if existing && !existing[:locked] && existing[:response_body].present?
          Idempo.logger.info("[Idempo] Webhook HIT — duplicate ignored. key=#{idempo_key}")
          return existing.dig(:response_body, "result")
        end

        locked = Idempo.store.lock!(idempo_key, endpoint: self.class.name, request_hash: idempo_key)

        unless locked
          Idempo.logger.warn("[Idempo] Webhook LOCKED key=#{idempo_key}")
          existing = Idempo.store.find(idempo_key)
          return existing.dig(:response_body, "result") if existing&.dig(:response_body).present?
        end

        Idempo.logger.info("[Idempo] Webhook MISS — processing. key=#{idempo_key}")
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

      def compute_webhook_key(args, kwargs, key_fields, key_block)
        source = self.class._idempo_webhook_source || self.class.name

        raw = if key_block
          key_block.call(kwargs.empty? ? args.first : kwargs)
        else
          values = key_fields.map { |f| kwargs[f] || kwargs[f.to_s] }.compact
          "#{source}:#{values.join(":")}"
        end

        WEBHOOK_KEY_PREFIX + Digest::SHA256.hexdigest(raw.to_s)
      end

      def safe_serialize(value)
        value.respond_to?(:as_json) ? value.as_json : value.to_s
      rescue StandardError
        value.to_s
      end
    end
  end
end