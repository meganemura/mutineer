# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/rails_worker_db"

# #26/U5 — zero-dep unit coverage for the pure parts of the worker-DB adapter. The
# path-munging is the one bit of non-trivial logic that could break silently, so it
# gets a fast check here; the AR-backed routing is proven end-to-end in
# test/daemon_worker_db_test.rb (daemon suite, under the fixture app bundle).
class RailsWorkerDbTest < Minitest::Test
  def test_worker_database_path_inserts_worker_before_extension
    assert_equal "storage/test-0.sqlite3",
                 Mutineer::RailsWorkerDb.worker_database_path("storage/test.sqlite3", 0)
    assert_equal "storage/test-3.sqlite3",
                 Mutineer::RailsWorkerDb.worker_database_path("storage/test.sqlite3", 3)
  end

  def test_worker_database_path_handles_a_bare_name
    assert_equal "mydb-1", Mutineer::RailsWorkerDb.worker_database_path("mydb", 1)
  end

  # R10: the adapter must never touch AR unless the app loaded it. In the zero-dep
  # suite AR is absent, so `available?` must be a strict `false` (not nil) — the guard
  # every other method relies on.
  def test_available_reflects_active_record_presence
    expected = defined?(ActiveRecord::Base) ? true : false
    assert_equal expected, Mutineer::RailsWorkerDb.available?
  end

  # per_worker_config is pure (no AR), so the SQLite file naming is checked here.
  def test_per_worker_config_derives_sqlite_worker_database
    cfg = Mutineer::RailsWorkerDb.per_worker_config({ adapter: "sqlite3", database: "storage/test.sqlite3" }, 1)
    assert_equal "storage/test-1.sqlite3", cfg[:database]
    assert_equal "sqlite3", cfg[:adapter]
  end

  def test_per_worker_config_rejects_memory_database
    assert_raises(NotImplementedError) do
      Mutineer::RailsWorkerDb.per_worker_config({ adapter: "sqlite3", database: ":memory:" }, 0)
    end
  end

  # Only SQLite is routed by this module. A non-SQLite app gets its per-worker
  # database from database.yml under TEST_ENV_NUMBER, so a `-<w>` rename here would
  # point the fork at a database that does not exist.
  def test_routes_only_for_sqlite
    with_stub_active_record(adapter: "sqlite3", database: "storage/test.sqlite3") do
      assert Mutineer::RailsWorkerDb.routes?
    end
    with_stub_active_record(adapter: "postgresql", database: "app_test") do
      refute Mutineer::RailsWorkerDb.routes?
    end
  end

  def test_routes_is_false_without_active_record
    skip "ActiveRecord is loaded" if defined?(ActiveRecord::Base)

    refute Mutineer::RailsWorkerDb.routes?
  end

  def test_after_fork_leaves_a_postgres_connection_alone
    with_stub_active_record(adapter: "postgresql", database: "app_test") do |base|
      Mutineer::RailsWorkerDb.after_fork(1, nil)
      assert_empty base.established, "a non-SQLite connection must not be re-pointed"
    end
  end

  def test_after_fork_routes_a_sqlite_connection_to_the_worker_file
    with_stub_active_record(adapter: "sqlite3", database: "storage/test.sqlite3") do |base|
      Mutineer::RailsWorkerDb.after_fork(1, nil)
      assert_equal ["storage/test-1.sqlite3"], base.established.map { |c| c[:database] }
    end
  end

  def test_boot_database_returns_the_connected_name_for_postgres
    with_stub_active_record(adapter: "postgresql", database: "app_test2") do |base|
      assert_equal "app_test2", Mutineer::RailsWorkerDb.boot_database
      assert_equal ["SELECT 1"], base.executed, "boot must prove the connection works"
    end
  end

  def test_boot_database_reports_the_live_database_when_the_config_names_none
    with_stub_active_record(adapter: "postgresql", database: nil, live_database: "from_pgdatabase") do
      assert_equal "from_pgdatabase", Mutineer::RailsWorkerDb.boot_database
    end
  end

  def test_boot_database_prefers_the_live_database_over_the_config_name
    with_stub_active_record(adapter: "postgresql", database: "configured", live_database: "actual") do
      assert_equal "actual", Mutineer::RailsWorkerDb.boot_database
    end
  end

  def test_boot_database_lets_a_failed_connection_raise
    with_stub_active_record(adapter: "postgresql", database: "app_test9", execute_error: "database does not exist") do
      error = assert_raises(RuntimeError) { Mutineer::RailsWorkerDb.boot_database }
      assert_match(/does not exist/, error.message)
    end
  end

  def test_boot_database_is_nil_for_sqlite_and_does_not_connect
    with_stub_active_record(adapter: "sqlite3", database: "storage/test.sqlite3") do |base|
      assert_nil Mutineer::RailsWorkerDb.boot_database
      assert_empty base.executed
    end
  end

  def test_boot_database_is_nil_without_active_record
    skip "ActiveRecord is loaded" if defined?(ActiveRecord::Base)

    assert_nil Mutineer::RailsWorkerDb.boot_database
  end

  private

  # Stand-in for the app's ActiveRecord::Base: the zero-dep suite has no Rails, and
  # the module only needs the config, `establish_connection` and `execute`.
  StubBase = Struct.new(:adapter, :database, :execute_error, :established, :executed) do
    def connection_db_config
      Struct.new(:configuration_hash, :database).new({ adapter: adapter, database: database }, database)
    end

    def establish_connection(config)
      established << config
    end

    def connection
      self
    end

    def execute(sql)
      raise execute_error if execute_error

      executed << sql
    end
  end

  def with_stub_active_record(adapter:, database:, execute_error: nil, live_database: nil)
    skip "ActiveRecord is loaded" if defined?(ActiveRecord)

    base = StubBase.new(adapter, database, execute_error, [], [])
    base.define_singleton_method(:current_database) { live_database } if live_database
    Object.const_set(:ActiveRecord, Module.new)
    begin
      ActiveRecord.const_set(:Base, base)
      yield base
    ensure
      Object.send(:remove_const, :ActiveRecord)
    end
  end
end
