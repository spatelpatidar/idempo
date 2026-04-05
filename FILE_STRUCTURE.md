# Idempo — File Structure

```
idempo/
│
├── idempo.gemspec               # Gem metadata, dependencies, file manifest
├── Gemfile                      # Development dependencies (points to gemspec)
├── README.md                    # Full usage documentation
├── CHANGELOG.md                 # Version history
├── LICENSE.txt                  # MIT licence
├── FILE_STRUCTURE.md            # This file
│
├── .rspec                       # RSpec flags: --format documentation --color
├── .rubocop.yml                 # RuboCop configuration (style + Rails + RSpec)
├── .rubocop_todo.yml            # Auto-generated exclusions (starts empty)
│
├── lib/
│   ├── idempo.rb                # ← Entry point
│   │                            #   Requires all sub-modules, exposes:
│   │                            #   Idempo.configure / .store / .cleanup_expired! / .reset!
│   │
│   └── idempo/
│       ├── version.rb           # Idempo::VERSION = "1.0.0"
│       │
│       ├── errors.rb            # Custom exception hierarchy:
│       │                        #   Idempo::Error (base)
│       │                        #   Idempo::PayloadMismatchError  (key reused, different body)
│       │                        #   Idempo::ConcurrentRequestError (key locked by another worker)
│       │                        #   Idempo::InvalidKeyError        (bad key format/length)
│       │
│       ├── configuration.rb     # Idempo::Configuration
│       │                        #   All tuneable settings with documented defaults.
│       │                        #   Accessed via Idempo.configure { |c| ... }
│       │
│       ├── fingerprint.rb       # Idempo::Fingerprint (module_function)
│       │                        #   SHA-256 with JSON key-sorting so {"b":1,"a":2}
│       │                        #   and {"a":2,"b":1} hash identically.
│       │                        #   .for_request(request) → 64-char hex string
│       │                        #   .for_attributes(hash) → 64-char hex string
│       │
│       ├── controller.rb        # Idempo::Controller  (ActiveSupport::Concern)
│       │                        #   include Idempo::Controller
│       │                        #   idempotent only: [:create]
│       │                        #   Hooks: before_action  idempo_check_idempotency
│       │                        #          after_action   idempo_store_response
│       │                        #   Headers read:    Idempotency-Key
│       │                        #   Headers written: Idempo-Replay: true  (on replay)
│       │
│       ├── job.rb               # Idempo::Job  (ActiveSupport::Concern)
│       │                        #   include Idempo::Job
│       │                        #   idempotent_by :order_id
│       │                        #   idempotent_by :user_id, :email_type
│       │                        #   idempotent_by { |args| "custom-#{args[:id]}" }
│       │                        #   Wraps perform via prepend PerformWrapper
│       │
│       ├── webhook.rb           # Idempo::Webhook  (ActiveSupport::Concern)
│       │                        #   include Idempo::Webhook
│       │                        #   idempotent_by :event_id
│       │                        #   idempotent_by :event_id, source: "stripe"
│       │                        #   idempotent_by { |args| "#{args[:repo]}:#{args[:id]}" }
│       │                        #   Wraps process via prepend ProcessWrapper
│       │
│       ├── middleware.rb        # Idempo::Middleware  (Rack middleware)
│       │                        #   config.middleware.use Idempo::Middleware
│       │                        #   Options: path_prefix:, methods:
│       │                        #   Reads: HTTP_IDEMPOTENCY_KEY (Rack env key)
│       │
│       ├── railtie.rb           # Idempo::Railtie < Rails::Railtie
│       │                        #   Exposes generators, rake idempo:cleanup,
│       │                        #   autoloads IdempotencyKey model on :active_record
│       │
│       ├── models/
│       │   └── idempotency_key.rb   # Idempo::IdempotencyKey < ActiveRecord::Base
│       │                            #   table: idempotency_keys
│       │                            #   scopes: expired, active, locked, completed
│       │
│       ├── storage/
│       │   ├── active_record.rb # Idempo::Storage::ActiveRecord  (default)
│       │   │                    #   Uses DB INSERT + unique index as mutex.
│       │   │                    #   Methods: find / lock! / unlock_and_store!
│       │   │                    #            release_lock! / cleanup_expired!
│       │   │
│       │   └── redis.rb         # Idempo::Storage::Redis  (optional)
│       │                        #   Uses Redis SET NX for atomic locking.
│       │                        #   Built-in TTL — no cleanup job needed.
│       │                        #   Same interface as ActiveRecord store.
│       │
│       └── generators/
│           ├── install_generator.rb   # rails generate idempo:install
│           │                          # Idempo::Generators::InstallGenerator
│           │
│           └── idempo/
│               └── templates/
│                   ├── create_idempotency_keys.rb.erb   # Migration template
│                   │                                    # Creates idempotency_keys table
│                   │                                    # with all required columns + indexes
│                   │
│                   └── idempo_initializer.rb.erb        # config/initializers/idempo.rb
│                                                        # Pre-populated with all options
│
└── spec/
    ├── spec_helper.rb           # RSpec bootstrap:
    │                            #   - In-memory SQLite database
    │                            #   - Idempo::IdempotencyKey model (test-only)
    │                            #   - SQLite-compatible patches to Storage::ActiveRecord
    │                            #   - before(:each) resets all state + reconfigures
    │
    ├── idempo_spec.rb           # Top-level module: configure, store, logger,
    │                            #   cleanup_expired!, reset!
    │
    ├── configuration_spec.rb    # All defaults, mutability, Idempo.configure block
    │
    ├── errors_spec.rb           # PayloadMismatchError, ConcurrentRequestError,
    │                            #   InvalidKeyError  — hierarchy + messages
    │
    ├── fingerprint_spec.rb      # SHA-256 stability, JSON key-order invariance,
    │                            #   empty bodies, IO rewind, non-JSON content types
    │
    ├── storage_spec.rb          # ActiveRecord store: lock! / find / unlock_and_store!
    │                            #   release_lock! / cleanup_expired!
    │                            #   including expiry and race-condition tests
    │
    ├── job_spec.rb              # First execution, duplicate prevention, multi-field keys,
    │                            #   custom block keys, opt-out, error recovery + lock release
    │
    └── webhook_spec.rb          # First processing, duplicate dedup, source namespacing,
                                 #   custom block keys, opt-out, error recovery + lock release
```

---

## Data Flow

```
                        ┌─────────────────────────────────────────┐
                        │           HTTP Request arrives           │
                        └────────────────┬────────────────────────┘
                                         │
                        ┌────────────────▼────────────────────────┐
                        │  Idempotency-Key header present?        │
                        └────────────────┬────────────────────────┘
                      NO │                              │ YES
                         ▼                              ▼
                  ┌─────────────┐       ┌───────────────────────────┐
                  │ Pass through│       │ Validate key format/length │
                  └─────────────┘       └──────────────┬────────────┘
                                                        │
                                        ┌───────────────▼────────────┐
                                        │  store.find(key)           │
                                        └──────┬──────────┬──────────┘
                                    FOUND      │          │  NOT FOUND
                              ┌────────────────┘          └──────────────────┐
                              ▼                                               ▼
                  ┌───────────────────────┐                  ┌───────────────────────────┐
                  │  locked?              │                   │  store.lock!(key)         │
                  └─────┬─────────┬───────┘                  └──────────┬────────────────┘
               YES      │         │ NO                        FAILED    │           SUCCESS
                        ▼         ▼                                     ▼                ▼
              ┌──────────┐  ┌────────────────┐        ┌──────────────────┐   ┌──────────────────┐
              │ 409      │  │ response_body? │         │ 409 Conflict     │   │  Run controller  │
              │ Conflict │  └──┬──────────┬──┘         │ (another worker) │   │  action (MISS)   │
              └──────────┘  YES│          │NO           └──────────────────┘   └────────┬─────────┘
                               ▼          ▼                                             │
                      ┌──────────────┐  ┌────────┐                          ┌───────────▼──────────┐
                      │ Replay       │  │ 409    │                          │  after_action:        │
                      │ stored resp  │  │Conflict│                          │  store response body  │
                      │ (HIT) ✓      │  └────────┘                          │  release lock         │
                      └──────────────┘                                      └──────────────────────┘
```

---

## Storage Schema

```
Table: idempotency_keys
┌──────────────────┬──────────────┬──────────────────────────────────────────────────┐
│ Column           │ Type         │ Purpose                                          │
├──────────────────┼──────────────┼──────────────────────────────────────────────────┤
│ id               │ bigint PK    │ Auto-generated primary key                       │
│ key              │ string(255)  │ Client-supplied idempotency key (UNIQUE INDEX)   │
│ endpoint         │ string(255)  │ "controller#action" or job/webhook class name    │
│ request_hash     │ string(64)   │ SHA-256 of request body (payload match guard)    │
│ response_body    │ jsonb        │ Stored response replayed on duplicate requests   │
│ response_status  │ integer      │ HTTP status code of original response            │
│ locked           │ boolean      │ true = request in-flight (soft mutex)            │
│ expires_at       │ datetime     │ Record TTL — rows deleted by cleanup_expired!    │
│ created_at       │ datetime     │ Standard Rails timestamp                         │
│ updated_at       │ datetime     │ Standard Rails timestamp                         │
└──────────────────┴──────────────┴──────────────────────────────────────────────────┘

Indexes:
  idx_idempotency_keys_key              UNIQUE  (key)               ← primary mutex
  idx_idempotency_keys_expires_at               (expires_at)        ← fast cleanup
  idx_idempotency_keys_endpoint_expires         (endpoint, expires_at)
```