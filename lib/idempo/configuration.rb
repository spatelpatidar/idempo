# frozen_string_literal: true

module Idempo
  # Holds all tuneable settings for the gem.
  # Construct via Idempo.configure { |c| ... } in an initializer.
  class Configuration
    # @return [Integer] TTL for stored idempotency records (seconds). Default: 86_400 (24 h).
    attr_accessor :expiry

    # @return [Boolean] Raise PayloadMismatchError on key + different payload. Default: true.
    attr_accessor :enforce_payload_match

    # @return [Boolean] Store and replay responses for duplicate requests. Default: true.
    attr_accessor :store_response

    # @return [Object] Backing store instance. Must implement the Storage interface.
    attr_accessor :store

    # @return [Logger] Where to send [Idempo] HIT/MISS/LOCKED log lines.
    attr_accessor :logger

    # @return [Integer] Maximum character length for an idempotency key. Default: 255.
    attr_accessor :max_key_length

    # @return [Array<Integer>] HTTP statuses whose responses are NOT cached. Default: 500-599.
    attr_accessor :non_cacheable_statuses

    # @return [Redis, nil] Optional Redis client for the Redis storage backend.
    attr_accessor :redis

    def initialize
      @expiry                 = 24 * 60 * 60 # 86_400 seconds
      @enforce_payload_match  = true
      @store_response         = true
      @store                  = Idempo::Storage::ActiveRecord.new
      @logger                 = default_logger
      @max_key_length         = 255
      @non_cacheable_statuses = (500..599).to_a
      @redis                  = nil
    end

    private

    def default_logger
      return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Logger.new($stdout, progname: "Idempo")
    end
  end
end