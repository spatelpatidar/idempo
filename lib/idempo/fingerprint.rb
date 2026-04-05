# frozen_string_literal: true

require "digest"
require "json"

module Idempo
  # Produces a deterministic SHA-256 fingerprint that identifies a unique
  # request payload. JSON bodies are key-sorted before hashing so that
  # {"b":2,"a":1} and {"a":1,"b":2} produce the same digest.
  #
  # Fingerprints cover:
  #   - HTTP method (uppercased)
  #   - Full request path (including query string)
  #   - Canonicalized request body
  module Fingerprint
    module_function

    # Compute a fingerprint for a Rack/ActionDispatch request object.
    #
    # @param request [ActionDispatch::Request, Rack::Request]
    # @return [String] 64-character hex SHA-256 digest
    def for_request(request)
      method           = request.request_method.upcase
      path             = request.fullpath
      raw_body         = read_body(request)
      canonical_body   = canonicalize(raw_body, content_type_from(request))

      Digest::SHA256.hexdigest("#{method}\n#{path}\n#{canonical_body}")
    end

    # Compute a fingerprint for a plain attributes hash (used by Job / Webhook).
    #
    # @param attrs [Hash]
    # @return [String] 64-character hex SHA-256 digest
    def for_attributes(attrs)
      Digest::SHA256.hexdigest(deep_sort_json(attrs))
    end

    # --- private helpers ----------------------------------------------------

    # Read and rewind the body IO so downstream code can still access it.
    def read_body(request)
      io = request.body
      return "" unless io

      io.rewind
      raw = io.read.to_s.strip
      io.rewind
      raw
    end

    def content_type_from(request)
      request.content_type.to_s.split(";").first.to_s.strip.downcase
    end

    # For JSON content types, parse → deep-sort keys → re-serialise so key
    # ordering differences don't affect the fingerprint.
    def canonicalize(body, content_type)
      return body unless content_type.include?("json")
      return ""   if body.empty?

      JSON.generate(deep_sort(JSON.parse(body)))
    rescue JSON::ParserError
      body
    end

    # Recursively sort Hash keys; leave other types untouched.
    def deep_sort(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, memo| memo[key] = deep_sort(value[key]) }
      when Array
        value.map { |item| deep_sort(item) }
      else
        value
      end
    end

    def deep_sort_json(value)
      JSON.generate(deep_sort(value))
    end
  end
end