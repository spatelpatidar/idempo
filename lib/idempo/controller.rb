# frozen_string_literal: true

module Idempo
  # ActiveSupport::Concern that adds idempotency enforcement to Rails controllers.
  #
  # Opt-in at the controller level — never applied globally.
  #
  # @example Protect specific actions
  #   class OrdersController < ApplicationController
  #     include Idempo::Controller
  #     idempotent only: [:create]
  #   end
  #
  # @example Protect all actions
  #   class PaymentsController < ApplicationController
  #     include Idempo::Controller
  #     idempotent
  #   end
  #
  # @example Exclude certain actions
  #   class InvoicesController < ApplicationController
  #     include Idempo::Controller
  #     idempotent except: [:index, :show]
  #   end
  module Controller
    extend ActiveSupport::Concern

    IDEMPOTENCY_KEY_HEADER = "Idempotency-Key"
    IDEMPO_REPLAY_HEADER   = "Idempo-Replay"

    included do
      class_attribute :_idempo_options, instance_writer: false
      self._idempo_options = {}
    end

    class_methods do
      # Declares which actions enforce idempotency.
      #
      # @param only   [Array<Symbol>] limit to these actions (omit for all)
      # @param except [Array<Symbol>] exclude these actions
      def idempotent(only: nil, except: nil)
        self._idempo_options = {
          only:   Array(only).map(&:to_s),
          except: Array(except).map(&:to_s),
        }
        before_action :idempo_check_idempotency
      end
    end

    private

    # before_action: checks whether the current action needs idempotency and,
    # when an Idempotency-Key header is present, either replays or processes.
    def idempo_check_idempotency
      return unless idempo_action_covered?

      idempotency_key = request.headers[IDEMPOTENCY_KEY_HEADER].presence
      return unless idempotency_key

      idempo_validate_key!(idempotency_key)

      fingerprint = Idempo::Fingerprint.for_request(request)

      existing = Idempo.store.find(idempotency_key)
      if existing
        return idempo_handle_existing(idempotency_key, existing, fingerprint)
      end

      idempo_acquire_lock_or_halt(idempotency_key, fingerprint)
    end

    # Handles an already-known key (HIT or locked).
    def idempo_handle_existing(idempotency_key, existing, fingerprint)
      if existing[:locked]
        Idempo.logger.warn("[Idempo] LOCKED key=#{idempotency_key}")
        return render(json: { error: "Request in progress" }, status: :conflict)
      end

      idempo_check_payload_match!(idempotency_key, existing, fingerprint)

      if existing[:response_body].present?
        Idempo.logger.info("[Idempo] HIT key=#{idempotency_key}")
        response.headers[IDEMPO_REPLAY_HEADER] = "true"
        return render(json: existing[:response_body], status: existing[:response_status])
      end
    end

    # Tries to acquire the lock; returns 409 if another worker beat us to it.
    def idempo_acquire_lock_or_halt(idempotency_key, fingerprint)
      locked = Idempo.store.lock!(
        idempotency_key,
        endpoint:     idempo_endpoint_identifier,
        request_hash: fingerprint,
      )

      unless locked
        existing = Idempo.store.find(idempotency_key)
        if existing&.dig(:response_body).present?
          Idempo.logger.info("[Idempo] HIT (race) key=#{idempotency_key}")
          response.headers[IDEMPO_REPLAY_HEADER] = "true"
          return render(json: existing[:response_body], status: existing[:response_status])
        end

        return render(json: { error: "Request in progress" }, status: :conflict)
      end

      Idempo.logger.info("[Idempo] MISS key=#{idempotency_key}")

      @_idempo_key         = idempotency_key
      @_idempo_fingerprint = fingerprint
      after_action :idempo_store_response
    end

    # after_action: persists the response so future duplicates are replayed.
    def idempo_store_response
      return unless @_idempo_key
      return unless Idempo.configuration.store_response

      status_code = response.status
      if Idempo.configuration.non_cacheable_statuses.include?(status_code)
        Idempo.store.release_lock!(@_idempo_key)
        return
      end

      body = parse_response_body(response.body)

      Idempo.store.unlock_and_store!(
        @_idempo_key,
        response_status: status_code,
        response_body:   body,
      )

      Idempo.logger.debug("[Idempo] STORED key=#{@_idempo_key} status=#{status_code}")
    rescue StandardError => e
      Idempo.logger.error("[Idempo] Failed to store response: #{e.message}")
      Idempo.store.release_lock!(@_idempo_key) rescue nil # rubocop:disable Style/RescueModifier
    end

    def idempo_action_covered?
      opts   = self.class._idempo_options
      return false if opts.blank?

      only   = opts[:only]
      except = opts[:except]

      return false if only.present?   && !only.include?(action_name)
      return false if except.present? && except.include?(action_name)

      true
    end

    def idempo_validate_key!(key)
      max = Idempo.configuration.max_key_length
      raise Idempo::InvalidKeyError, "Idempotency key exceeds maximum length of #{max}" if key.length > max
      raise Idempo::InvalidKeyError, "Idempotency key contains invalid characters" unless key.match?(/\A[\x20-\x7E]+\z/)
    end

    def idempo_endpoint_identifier
      "#{controller_path}##{action_name}"
    end

    def idempo_check_payload_match!(key, existing, current_fingerprint)
      return if existing[:request_hash] == current_fingerprint

      if Idempo.configuration.enforce_payload_match
        raise Idempo::PayloadMismatchError, key
      else
        Idempo.logger.warn(
          "[Idempo] PAYLOAD MISMATCH key=#{key} — returning cached response " \
          "(enforce_payload_match is false)"
        )
      end
    end

    def parse_response_body(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      { raw: raw }
    end
  end
end