# frozen_string_literal: true

module Idempo
  # ActiveRecord model that backs the idempotency store.
  #
  # The table is created by running:
  #   rails generate idempo:install && rails db:migrate
  class IdempotencyKey < ActiveRecord::Base
    self.table_name = "idempotency_keys"

    validates :key,      presence: true, uniqueness: true, length: { maximum: 255 }
    validates :endpoint, presence: true

    scope :expired,   -> { where("expires_at < ?", Time.current) }
    scope :active,    -> { where("expires_at >= ?", Time.current) }
    scope :locked,    -> { where(locked: true) }
    scope :completed, -> { where(locked: false).where.not(response_body: nil) }
  end
end