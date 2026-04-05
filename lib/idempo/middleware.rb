# frozen_string_literal: true

module Idempo
  # Optional Rack middleware that applies idempotency at the Rack layer.
  #
  # Prefer {Idempo::Controller} for Rails apps. Use this middleware for
  # Sinatra, Grape, or when you need blanket coverage across all routes.
  #
  # @example Mount globally
  #   # config/application.rb
  #   config.middleware.use Idempo::Middleware
  #
  # @example Mount for a path prefix
  #   config.middleware.use Idempo::Middleware, path_prefix: "/api"
  #
  # @example Restrict to specific HTTP methods
  #   config.middleware.use Idempo::Middleware, methods: %w[POST PUT PATCH]
  class Middleware
    IDEMPOTENCY_KEY_HEADER  = "HTTP_IDEMPOTENCY_KEY"
    IDEMPO_REPLAY_HEADER    = "Idempo-Replay"
    DEFAULT_COVERED_METHODS = %w[POST PUT PATCH DELETE].freeze

    # @param app         [#call]          Rack application
    # @param path_prefix [String, nil]    only cover paths that start with this
    # @param methods     [Array<String>]  HTTP methods to cover
    def initialize(app, path_prefix: nil, methods: DEFAULT_COVERED_METHODS)
      @app         = app
      @path_prefix = path_prefix
      @methods     = Array(methods).map(&:upcase)
    end

    def call(env)
      return @app.call(env) unless covered?(env)

      idempotency_key = env[IDEMPOTENCY_KEY_HEADER].presence
      return @app.call(env) unless idempotency_key

      fingerprint = Idempo::Fingerprint.for_request(rack_request(env))
      existing    = Idempo.store.find(idempotency_key)

      return handle_existing(existing, idempotency_key, fingerprint) if existing

      process_new_request(env, idempotency_key, fingerprint)
    rescue Idempo::PayloadMismatchError => e
      Idempo.logger.warn("[Idempo] Middleware PAYLOAD MISMATCH key=#{idempotency_key}")
      error_response(409, e.message)
    rescue Idempo::InvalidKeyError => e
      error_response(400, e.message)
    end

    private

    def covered?(env)
      return false unless @methods.include?(env["REQUEST_METHOD"])
      return true  unless @path_prefix

      env["PATH_INFO"].start_with?(@path_prefix)
    end

    def handle_existing(existing, key, current_fingerprint)
      if existing[:locked]
        Idempo.logger.warn("[Idempo] Middleware LOCKED key=#{key}")
        return conflict_response
      end

      if Idempo.configuration.enforce_payload_match && existing[:request_hash] != current_fingerprint
        raise Idempo::PayloadMismatchError, key
      end

      if existing[:response_body].present?
        Idempo.logger.info("[Idempo] Middleware HIT key=#{key}")
        return replay_response(existing)
      end

      conflict_response
    end

    def process_new_request(env, key, fingerprint)
      locked = Idempo.store.lock!(
        key,
        endpoint:     "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}",
        request_hash: fingerprint,
      )

      unless locked
        Idempo.logger.warn("[Idempo] Middleware LOCKED (race) key=#{key}")
        return conflict_response
      end

      Idempo.logger.info("[Idempo] Middleware MISS key=#{key}")
      status, headers, body = @app.call(env)
      persist_response(key, status, body)
      [status, headers, body]
    end

    def persist_response(key, status, body)
      return unless Idempo.configuration.store_response
      return if Idempo.configuration.non_cacheable_statuses.include?(status)

      body_str = +""
      body.each { |chunk| body_str << chunk }

      parsed = JSON.parse(body_str)

      Idempo.store.unlock_and_store!(
        key,
        response_status: status,
        response_body:   parsed,
      )
    rescue JSON::ParserError
      Idempo.store.unlock_and_store!(key, response_status: status, response_body: { raw: body_str })
    rescue StandardError => e
      Idempo.logger.error("[Idempo] Middleware failed to store response: #{e.message}")
      Idempo.store.release_lock!(key) rescue nil # rubocop:disable Style/RescueModifier
    end

    def replay_response(existing)
      body    = JSON.generate(existing[:response_body])
      headers = {
        "Content-Type"    => "application/json",
        "Content-Length"  => body.bytesize.to_s,
        IDEMPO_REPLAY_HEADER => "true",
      }
      [existing[:response_status], headers, [body]]
    end

    def conflict_response
      json_response(409, error: "Request in progress")
    end

    def error_response(status, message)
      json_response(status, error: message)
    end

    def json_response(status, payload)
      body = JSON.generate(payload)
      [status, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
    end

    def rack_request(env)
      require "rack"
      ::Rack::Request.new(env)
    end
  end
end