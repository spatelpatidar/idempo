# frozen_string_literal: true

module Idempo
  # Base class for all Idempo exceptions.
  class Error < StandardError; end

  # Raised when the same idempotency key is reused with a different request
  # payload. The client has a bug — keys must be paired with identical payloads
  # on every retry.
  class PayloadMismatchError < Error
    attr_reader :idempotency_key

    def initialize(idempotency_key)
      @idempotency_key = idempotency_key
      super(
        "Idempotency key '#{idempotency_key}' was already used with a different " \
        "request payload. Idempotency keys must be paired with identical payloads on retries."
      )
    end
  end

  # Raised (internally) when a request is detected while the same key is already
  # being processed by another worker/thread.
  class ConcurrentRequestError < Error
    def initialize(idempotency_key)
      super(
        "A request with idempotency key '#{idempotency_key}' is already being " \
        "processed. Please retry after the original request completes."
      )
    end
  end

  # Raised when a supplied idempotency key is too long or contains
  # non-printable characters.
  class InvalidKeyError < Error; end
end