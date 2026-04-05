# frozen_string_literal: true

module Idempo
  module Storage
    # Optional Redis-backed idempotency store.
    #
    # Advantages over the ActiveRecord store:
    #   - Sub-millisecond lookups
    #   - Built-in TTL — no +rake idempo:cleanup+ job required
    #   - Better fit for very high-throughput APIs
    #
    # @example Configure in initializer
    #   Idempo.configure do |config|
    #     config.redis = Redis.new(url: ENV.fetch("REDIS_URL"))
    #     config.store = Idempo::Storage::Redis.new
    #   end
    class Redis
      KEY_PREFIX = "idempo:"

      # @param client [::Redis, nil] Redis client; defaults to config.redis
      def initialize(client = nil)
        @client = client || Idempo.configuration.redis || raise(
          Idempo::Error,
          "Idempo::Storage::Redis requires a Redis client. " \
          "Set `config.redis = Redis.new(url: ENV.fetch(\"REDIS_URL\"))` in your initializer."
        )
      end

      # @param key [String]
      # @return [Hash, nil]
      def find(key)
        raw = @client.get(namespaced(key))
        return nil unless raw

        data = JSON.parse(raw, symbolize_names: true)
        {
          key:             data[:key],
          endpoint:        data[:endpoint],
          request_hash:    data[:request_hash],
          response_body:   data[:response_body] ? JSON.parse(data[:response_body]) : nil,
          response_status: data[:response_status],
          locked:          data[:locked],
        }
      rescue JSON::ParserError
        nil
      end

      # Atomically acquires a lock via SET NX (set-if-not-exists).
      #
      # @return [Boolean] true when the lock was acquired
      def lock!(key, endpoint:, request_hash:)
        ttl = Idempo.configuration.expiry.ceil
        payload = build_payload(key: key, endpoint: endpoint, request_hash: request_hash, locked: true)

        result = @client.set(namespaced(key), payload, nx: true, ex: ttl)
        result == true || result == "OK"
      end

      # Stores the final response and flips +locked+ to false.
      #
      # @return [void]
      def unlock_and_store!(key, response_status:, response_body:)
        raw = @client.get(namespaced(key))
        return unless raw

        existing    = JSON.parse(raw, symbolize_names: true)
        ttl_seconds = [@client.ttl(namespaced(key)), 1].max

        updated = existing.merge(
          response_status: response_status,
          response_body:   JSON.generate(response_body),
          locked:          false,
        )

        @client.set(namespaced(key), JSON.generate(updated), ex: ttl_seconds)
      end

      # Deletes the lock record so the operation can be retried.
      #
      # @return [void]
      def release_lock!(key)
        @client.del(namespaced(key))
      end

      # Redis TTLs handle expiry automatically — this is a no-op.
      #
      # @return [Integer] always 0
      def cleanup_expired!
        0
      end

      private

      def namespaced(key)
        "#{KEY_PREFIX}#{key}"
      end

      def build_payload(key:, endpoint:, request_hash:, locked:)
        JSON.generate(
          key:             key,
          endpoint:        endpoint,
          request_hash:    request_hash,
          response_body:   nil,
          response_status: nil,
          locked:          locked,
        )
      end
    end
  end
end