# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Idempo
  module Generators
    # Interactive installer for Idempo.
    #
    # Walks the user through a numbered-menu wizard — no free-text input
    # required. Every prompt shows all valid options so the user just presses
    # a number key. Confirms before writing any files; pressing any key other
    # than Y/Enter cancels without touching the project.
    #
    # @example Interactive
    #   rails generate idempo:install
    #
    # @example Fully scripted (CI)
    #   rails generate idempo:install --storage=redis --expiry=48.hours \
    #     --enforce-payload-match --skip-confirm
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("idempo/templates", __dir__)

      desc "Interactively installs Idempo — idempotency for Rails APIs, jobs, and webhooks."

      # ── CI / scripting flags (skip individual prompts) ────────────────────

      class_option :expiry,
        type:    :string,
        default: nil,
        desc:    "Key expiry. Options: 1.hour | 24.hours | 48.hours | 7.days | 30.days"

      class_option :storage,
        type:    :string,
        default: nil,
        desc:    "Storage backend. Options: active_record | redis"

      class_option :enforce_payload_match,
        type:    :boolean,
        default: nil,
        desc:    "Raise on key + different payload reuse (true/false)"

      class_option :store_response,
        type:    :boolean,
        default: nil,
        desc:    "Store and replay original response for duplicates (true/false)"

      class_option :skip_confirm,
        type:    :boolean,
        default: false,
        desc:    "Skip the final Y/n confirmation (for CI pipelines)"

      # ── Thor entry point ──────────────────────────────────────────────────

      def run_interactive_installer
        print_banner
        gather_options
        print_summary
        confirm_and_install
      end

      private

      # ── Banner ────────────────────────────────────────────────────────────

      def print_banner
        say ""
        say "  ╔══════════════════════════════════════════════════════════╗", :cyan
        say "  ║        Idempo — Idempotency Installer  v#{Idempo::VERSION.ljust(14)}║", :cyan
        say "  ║   Prevents duplicate API requests, jobs & webhooks       ║", :cyan
        say "  ╚══════════════════════════════════════════════════════════╝", :cyan
        say ""
        say "  Answer each question by entering the option number.", :white
        say "  Press Enter to accept the default shown in [brackets].", :white
        say ""
      end

      # ── Option gathering ──────────────────────────────────────────────────

      def gather_options
        @config = {}
        ask_project_name
        ask_storage_backend
        ask_expiry
        ask_enforce_payload_match
        ask_store_response
      end

      # Step 1 ── project name (free text, only used in generated comments)
      def ask_project_name
        print_step(1, "Project name")
        say "  Used only in generated file comments.", :white
        say ""

        @config[:app_name] = if options[:app_name]
          options[:app_name].tap { |v| say "  ✔  #{v} (from --app-name flag)", :green }
        else
          ask("  ❯ Your Rails app name", default: rails_app_name)
        end
        say ""
      end

      # Step 2 ── storage backend
      def ask_storage_backend
        print_step(2, "Storage backend")

        menu_rows = [
          ["1", "active_record", "Recommended — uses your existing DB, zero extra infra"],
          ["2", "redis",         "Optional   — sub-ms lookups, built-in TTL, no cleanup job"],
        ]
        print_menu(menu_rows, default_marker: "1")

        @config[:storage] = if options[:storage]
          options[:storage].tap { |v| say "  ✔  #{v} (from --storage flag)", :green }
        else
          choice = ask_numbered("  ❯ Choose storage backend [1]", valid: %w[1 2], default: "1")
          choice == "2" ? "redis" : "active_record"
        end

        if @config[:storage] == "redis"
          say ""
          say "  ⚠  Redis selected. Remember to add to your Gemfile:", :yellow
          say "       gem \"redis\"", :yellow
        end
        say ""
      end

      # Step 3 ── key expiry
      def ask_expiry
        print_step(3, "Idempotency key expiry")
        say "  How long should processed-request records be kept?", :white
        say "  Records older than this are removed by `rake idempo:cleanup`.", :white
        say ""

        menu_rows = [
          ["1", "1.hour",   "Short-lived  — good for real-time payment APIs"],
          ["2", "24.hours", "One day      — recommended default"],
          ["3", "48.hours", "Two days     — safer for slow retry queues"],
          ["4", "7.days",   "One week     — conservative, higher DB storage cost"],
          ["5", "30.days",  "One month    — maximum retention"],
        ]
        print_menu(menu_rows, default_marker: "2")

        expiry_map = {
          "1" => "1.hour",
          "2" => "24.hours",
          "3" => "48.hours",
          "4" => "7.days",
          "5" => "30.days",
        }

        @config[:expiry] = if options[:expiry]
          options[:expiry].tap { |v| say "  ✔  #{v} (from --expiry flag)", :green }
        else
          choice = ask_numbered("  ❯ Choose expiry [2]", valid: %w[1 2 3 4 5], default: "2")
          expiry_map[choice]
        end
        say ""
      end

      # Step 4 ── payload match enforcement
      def ask_enforce_payload_match
        print_step(4, "Payload mismatch enforcement")
        say "  What happens when the same key is sent with a different request body?", :white
        say ""

        menu_rows = [
          ["1", "true  (recommended)", "Raise PayloadMismatchError → 409 Conflict. Catches client bugs."],
          ["2", "false",               "Log a warning and replay the cached response silently."],
        ]
        print_menu(menu_rows, default_marker: "1")

        @config[:enforce_payload_match] = if !options[:enforce_payload_match].nil?
          options[:enforce_payload_match].tap { |v| say "  ✔  #{v} (from --enforce-payload-match flag)", :green }
        else
          choice = ask_numbered("  ❯ Choose behaviour [1]", valid: %w[1 2], default: "1")
          choice == "1"
        end
        say ""
      end

      # Step 5 ── response replay
      def ask_store_response
        print_step(5, "Duplicate request handling")
        say "  What should Idempo return for a duplicate request (same key, same body)?", :white
        say ""

        menu_rows = [
          ["1", "true  (recommended)", "Return the exact original HTTP status + JSON body (replay)."],
          ["2", "false",               "Block the duplicate — return 409 without a body."],
        ]
        print_menu(menu_rows, default_marker: "1")

        @config[:store_response] = if !options[:store_response].nil?
          options[:store_response].tap { |v| say "  ✔  #{v} (from --store-response flag)", :green }
        else
          choice = ask_numbered("  ❯ Choose behaviour [1]", valid: %w[1 2], default: "1")
          choice == "1"
        end
        say ""
      end

      # ── Summary box ───────────────────────────────────────────────────────

      def print_summary
        say "  ┌─ Installation plan ─────────────────────────────────────────┐", :cyan
        summary_row "App name",        @config[:app_name].to_s
        summary_row "Storage backend", @config[:storage].to_s
        summary_row "Key expiry",      @config[:expiry].to_s
        summary_row "Payload match",   @config[:enforce_payload_match].to_s
        summary_row "Response replay", @config[:store_response].to_s
        say "  │                                                               │", :cyan
        say "  │  Files that will be created:                                  │", :cyan
        say "  │    ✦  db/migrate/TIMESTAMP_create_idempotency_keys.rb         │", :cyan
        say "  │    ✦  config/initializers/idempo.rb                           │", :cyan
        say "  │                                                               │", :cyan
        say "  └───────────────────────────────────────────────────────────────┘", :cyan
        say ""
      end

      # ── Confirmation ──────────────────────────────────────────────────────

      def confirm_and_install
        if options[:skip_confirm]
          say "  ⏭  Skipping confirmation (--skip-confirm)", :yellow
          say ""
          perform_installation
          return
        end

        say "  ┌─────────────────────────────────────────────────────────────┐", :white
        say "  │  Press  Y  or  Enter  to install.                           │", :white
        say "  │  Press  any other key  to cancel without creating files.    │", :white
        say "  └─────────────────────────────────────────────────────────────┘", :white
        say ""
        print "  ❯ Install Idempo? [Y/n]  "
        $stdout.flush

        input = read_single_char.strip.downcase
        say ""
        say ""

        if input == "y" || input == ""
          perform_installation
        else
          say "  ✗  Cancelled. No files were created.", :red
          say ""
          say "  To run the installer again:", :white
          say "    rails generate idempo:install", :white
          say ""
        end
      end

      # ── File generation ───────────────────────────────────────────────────

      def perform_installation
        say "  ⚙  Installing Idempo...", :green
        say ""

        generate_migration_file
        create_initializer
        print_next_steps
      end

      def generate_migration_file
        say "  Creating migration...", :white
        # Rails 7.1 changed migration_template — the third options hash was removed.
        # Set @migration_version as an instance variable so the ERB template
        # can access it directly via @migration_version.
        @migration_version = migration_version
        migration_template(
          "create_idempotency_keys.rb.erb",
          "db/migrate/create_idempotency_keys.rb",
        )
      end

      def create_initializer
        say "  Creating initializer...", :white
        # Expose config to the ERB template via instance variables
        @storage_backend = @config[:storage]
        @expiry_value    = @config[:expiry]
        @enforce_match   = @config[:enforce_payload_match]
        @store_response  = @config[:store_response]
        @app_name        = @config[:app_name]

        template "idempo_initializer.rb.erb", "config/initializers/idempo.rb"
      end

      def print_next_steps
        say ""
        say "  ┌─ Next steps ─────────────────────────────────────────────────┐", :green
        say "  │                                                               │", :green
        say "  │  1.  Run the migration:                                       │", :green
        say "  │        rails db:migrate                                       │", :green
        say "  │                                                               │", :green
        say "  │  2.  Add idempotency to a controller:                         │", :green
        say "  │        class OrdersController < ApplicationController         │", :green
        say "  │          include Idempo::Controller                           │", :green
        say "  │          idempotent only: [:create]                           │", :green
        say "  │        end                                                    │", :green
        say "  │                                                               │", :green
        say "  │  3.  Clients send requests with:                              │", :green
        say "  │        Idempotency-Key: <uuid>                                │", :green
        say "  │                                                               │", :green
        say "  │  4.  Schedule periodic cleanup:                               │", :green
        say "  │        rake idempo:cleanup                                    │", :green

        if @config[:storage] == "redis"
          say "  │                                                               │", :green
          say "  │  5.  Configure Redis in config/initializers/idempo.rb:        │", :green
          say "  │        config.redis = Redis.new(url: ENV[\"REDIS_URL\"])        │", :green
        end

        say "  │                                                               │", :green
        say "  └───────────────────────────────────────────────────────────────┘", :green
        say ""
        say "  ✓  Idempo installed successfully!", :green
        say ""
      end

      # ── Display helpers ───────────────────────────────────────────────────

      def print_step(number, title)
        say "  ─────────────────────────────────────────────────────────────", :white
        say "  Step #{number} of 5 — #{title}", :bold
        say ""
      end

      # Renders a numbered option menu.
      # menu_rows: Array of [number_str, value_str, description_str]
      def print_menu(rows, default_marker: "1")
        rows.each do |num, value, description|
          marker  = num == default_marker ? " (default)" : ""
          num_col = "  [#{num}]"
          val_col = value.ljust(22)
          say "#{num_col}  #{val_col}#{description}#{marker}", :white
        end
        say ""
      end

      # Renders one row of the summary box.
      def summary_row(label, value)
        label_col = label.ljust(18)
        value_col = value.ljust(43)
        say "  │  #{label_col}: #{value_col}│", :cyan
      end

      # Prompts for a number choice with validation and default support.
      def ask_numbered(prompt, valid:, default:)
        loop do
          raw = ask(prompt)
          raw = raw.strip
          return default if raw.empty?
          return raw     if valid.include?(raw)

          say "  ✗  Invalid choice '#{raw}'. Please enter one of: #{valid.join(", ")}", :red
          say ""
        end
      end

      # ── Utility helpers ───────────────────────────────────────────────────

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def rails_app_name
        return ::Rails.application.class.module_parent_name if defined?(::Rails)

        "MyApp"
      rescue StandardError
        "MyApp"
      end

      # Read one keypress without requiring Enter.
      # Falls back to full-line input in CI / non-TTY environments.
      def read_single_char
        require "io/console"
        $stdin.getch
      rescue LoadError, Errno::ENOTTY, Errno::EINVAL
        $stdin.gets.to_s.strip
      end
    end
  end
end