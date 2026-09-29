# frozen_string_literal: true

module Mutineer
  # Per-worker database isolation for the daemon path.
  #
  # Loaded APP-SIDE by {DaemonServer} (a sibling gem file, pulled in by absolute
  # path so it bypasses the app bundle, the same trick {DaemonClient} uses to run
  # `daemon_server.rb` under a bundle that has no mutineer). It uses the app's
  # OWN already-booted ActiveRecord and NEVER `require "active_record"`: every
  # method that touches AR first confirms {available?}, so the daemon core stays
  # framework-agnostic and the gem keeps its zero-runtime-dependency promise.
  #
  # Isolation model: each parallel worker gets its OWN database so concurrent
  # forks cannot clobber each other's transactional fixtures. {after_fork} runs
  # inside a freshly-forked child and points that child's connection at the
  # worker's database BEFORE any test loads; transactional fixtures then
  # repopulate that isolated database per test.
  #
  # Scope: SQLite only (per-worker file, hermetic). Any other adapter is left
  # alone: its per-worker database comes from database.yml evaluated under the
  # `TEST_ENV_NUMBER` that {DaemonClient} sets at spawn (the parallel_tests
  # convention), and {boot_database} proves it connects. Creating those
  # databases is the app's job, as it is with parallel_tests. A `-<worker>`
  # rename cannot work there: a Postgres database must exist before it is used.
  #
  # Routing failures surface as `error` via {verify_connection!}. Tagging an
  # in-test DB failure as `error` (not `killed`) is only observable under
  # concurrent load and is not yet implemented.
  module RailsWorkerDb
    # True when the app has ActiveRecord loaded. The only condition under which
    # any other method here may touch AR. Never triggers an autoload/require of
    # AR itself.
    #
    # @return [Boolean]
    def self.available?
      defined?(ActiveRecord::Base) ? true : false
    end

    # Derive a per-worker database path from a base path by inserting `-<worker>`
    # before the extension. Pure string transform (no AR) so it is unit-testable
    # in the zero-dep suite. `storage/test.sqlite3`, worker 1 ->
    # `storage/test-1.sqlite3`.
    #
    # @param database [String] the base database path.
    # @param worker [Integer] the worker slot index (0..N-1).
    # @return [String] the per-worker database path.
    def self.worker_database_path(database, worker)
      ext = File.extname(database)
      "#{database.delete_suffix(ext)}-#{worker}#{ext}"
    end

    # True when this module owns per-worker routing: ActiveRecord is loaded and
    # its adapter is SQLite. Every other adapter is routed by database.yml under
    # `TEST_ENV_NUMBER`, so {after_fork} must leave its connection alone.
    #
    # @return [Boolean]
    def self.routes?
      available? && sqlite?(ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    # Boot-time check for a non-SQLite app: connect once and return the database
    # name the daemon resolved, so a wrong or missing per-worker database fails
    # at boot instead of as a false verdict per mutant. SQLite is routed per
    # fork and needs no boot check.
    #
    # The name comes from the live connection, not from database.yml: with
    # `PGDATABASE` and no `database:` key the config has no name, and a worker
    # that reports none would slip past the duplicate-database guard.
    #
    # @return [String, nil] the connected database name, or nil for SQLite or no AR.
    def self.boot_database
      return nil unless available?

      config = ActiveRecord::Base.connection_db_config
      return nil if sqlite?(config.configuration_hash)

      verify_connection!
      connection = ActiveRecord::Base.connection
      connection.respond_to?(:current_database) ? connection.current_database : config.database
    end

    # Build the AR connection config for one worker by copying the app's current
    # (default test) config and swapping in the per-worker database path. Only
    # called for SQLite (see {routes?}).
    #
    # @param worker [Integer] the worker slot index.
    # @return [Hash] a symbol-keyed AR configuration hash for the worker database.
    # @raise [NotImplementedError] when the app's database is in-memory.
    def self.worker_db_config(worker)
      per_worker_config(ActiveRecord::Base.connection_db_config.configuration_hash, worker)
    end

    # Pure config-shaping (no AR): given a connection config hash, return the
    # per-worker variant with its database swapped to the worker's own name
    # (`storage/test.sqlite3` -> `storage/test-<w>.sqlite3`) via
    # {worker_database_path}. Extracted so the shaping is unit-tested without AR.
    #
    # @param config_hash [Hash] a connection config hash (symbol or string keys).
    # @param worker [Integer] the worker slot index.
    # @return [Hash] the per-worker config (symbol keys), database swapped.
    # @raise [NotImplementedError] for an in-memory or empty database (no per-worker split).
    def self.per_worker_config(config_hash, worker)
      hash     = config_hash.transform_keys(&:to_sym)
      database = hash[:database].to_s
      if database.empty? || database == ":memory:"
        raise NotImplementedError,
              "worker-DB isolation needs a file/name-backed database (got #{database.inspect})."
      end

      hash.merge(database: worker_database_path(database, worker))
    end

    # Child-side (after fork): route this process's ActiveRecord at the worker's
    # own database and confirm it is reachable, so a routing failure reads as
    # `error` (via the daemon's child rescue) rather than a false verdict. Loads
    # the schema into the worker database when a schema path is given
    # (idempotent: schema.rb runs with `force: true`), covering a fresh worker
    # file.
    #
    # @param worker [Integer] the worker slot index.
    # @param schema_path [String, nil] absolute path to `db/schema.rb`, or nil to skip.
    # @return [void]
    def self.after_fork(worker, schema_path = nil)
      return unless routes?

      ActiveRecord::Base.establish_connection(worker_db_config(worker))
      load_schema(schema_path) if schema_path
      verify_connection!
    end

    # Load a Rails `schema.rb` into the current connection with output silenced
    # (fork child stdout is already File::NULL; this is belt-and-braces).
    #
    # @param schema_path [String] absolute path to `db/schema.rb`.
    # @return [void]
    def self.load_schema(schema_path)
      ActiveRecord::Migration.verbose = false if defined?(ActiveRecord::Migration)
      original = $stdout
      $stdout = File.open(File::NULL, "w")
      load schema_path
    ensure
      $stdout.close unless $stdout.equal?(original)
      $stdout = original
    end

    # Force a round-trip to the freshly-routed connection so a broken route fails
    # HERE (→ `error`) instead of later masquerading as a test failure
    # (→ false `killed`).
    #
    # @return [void]
    def self.verify_connection!
      ActiveRecord::Base.connection.execute("SELECT 1")
    end

    # @param config_hash [Hash] a connection config hash.
    # @return [Boolean] whether its adapter is SQLite.
    def self.sqlite?(config_hash)
      config_hash[:adapter].to_s.start_with?("sqlite")
    end
    private_class_method :sqlite?
  end
end
