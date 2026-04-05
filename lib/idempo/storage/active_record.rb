# frozen_string_literal: true

module Idempo
  module Storage
    # ActiveRecord-backed idempotency store.
    #
    # All public methods are thread-safe because concurrency is handled at the
    # database level via a UNIQUE index on the +key+ column.
    #
    # @example Configure (default — no action needed)
    #   Idempo.configure do |config|
    #     config.store = Idempo::Storage::ActiveRecord.new
    #   end
    class ActiveRecord
      MODEL_NAME = "Idempo::IdempotencyKey"

      # Finds a non-expired idempotency record by key.
      #
      # @param key [String]
      # @return [Hash, nil]
      def find(key)
        record = model.find_by(key: key)
        return nil if record.nil?
        return nil if record.expires_at && record.expires_at < Time.current

        serialize_record(record)
      end

      # Acquires a soft lock for an in-progress request.
      # Uses a plain INSERT so the DB unique index prevents double-locking.
      #
      # @param key          [String]
      # @param endpoint     [String]
      # @param request_hash [String]
      # @return [Boolean] true when the lock was acquired, false when already held
      def lock!(key, endpoint:, request_hash:)
        now = Time.current

        model.create!(
          key:          key,
          endpoint:     endpoint,
          request_hash: request_hash,
          locked:       true,
          expires_at:   now + Idempo.configuration.expiry,
          created_at:   now,
          updated_at:   now,
        )
        true
      rescue ::ActiveRecord::RecordNotUnique, ::ActiveRecord::RecordInvalid
        false
      end

      # Stores the final response and releases the lock atomically.
      #
      # @param key             [String]
      # @param response_status [Integer]
      # @param response_body   [Hash]
      # @return [void]
      def unlock_and_store!(key, response_status:, response_body:)
        model.where(key: key).update_all(
          locked:          false,
          response_status: response_status,
          response_body:   response_body,
          updated_at:      Time.current,
        )
      end

      # Releases the lock without storing a response (e.g. when the request raises).
      # Deletes the row entirely so the operation can be retried cleanly.
      #
      # @param key [String]
      # @return [void]
      def release_lock!(key)
        model.where(key: key, locked: true).delete_all
      end

      # Deletes all expired records. Safe to call from a scheduled job.
      #
      # @return [Integer] number of records deleted
      def cleanup_expired!
        model.where("expires_at < ?", Time.current).delete_all
      end

      private

      def model
        MODEL_NAME.constantize
      rescue NameError
        raise "Idempo: model #{MODEL_NAME} not found. " \
              "Did you run `rails generate idempo:install` and `rails db:migrate`?"
      end

      def serialize_record(record)
        {
          key:             record.key,
          endpoint:        record.endpoint,
          request_hash:    record.request_hash,
          response_body:   record.response_body,
          response_status: record.response_status,
          locked:          record.locked,
          expires_at:      record.expires_at,
        }
      end
    end
  end
end