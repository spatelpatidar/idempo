# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Idempo
  module Generators
    # Generates the migration and initializer needed to use Idempo.
    #
    # @example
    #   rails generate idempo:install
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("idempo/templates", __dir__)

      desc "Creates the idempotency_keys migration and an Idempo initializer"

      def create_migration_file
        migration_template(
          "create_idempotency_keys.rb.erb",
          "db/migrate/create_idempotency_keys.rb",
          migration_version: migration_version,
        )
      end

      def create_initializer_file
        template "idempo_initializer.rb.erb", "config/initializers/idempo.rb"
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end