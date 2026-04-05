# frozen_string_literal: true

module Idempo
  # Integrates Idempo into Rails via the Railtie API:
  #   - Exposes generators
  #   - Provides rake idempo:cleanup
  #   - Autoloads the IdempotencyKey ActiveRecord model
  class Railtie < Rails::Railtie
    generators do
      require "idempo/generators/install_generator"
    end

    rake_tasks do
      namespace :idempo do
        desc "Remove expired idempotency key records from the database"
        task cleanup: :environment do
          count = Idempo.cleanup_expired!
          puts "[Idempo] Deleted #{count} expired record(s)."
        end
      end
    end

    initializer "idempo.active_record_model" do
      ActiveSupport.on_load(:active_record) do
        require "idempo/models/idempotency_key"
      end
    end
  end
end