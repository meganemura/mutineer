# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_backend"

# Zero-dep checks for the two helpers that make `--jobs N` work on a non-SQLite
# database: the per-worker environment and the guard against workers sharing one.
class DaemonBackendEnvTest < Minitest::Test
  Backend = Mutineer::DaemonBackend
  Fake = Struct.new(:database)

  def test_worker_zero_gets_an_empty_test_env_number
    assert_equal({ "TEST_ENV_NUMBER" => "", "PARALLEL_TEST_GROUPS" => "3" }, Backend.worker_env(0, 3))
  end

  def test_later_workers_count_from_two
    assert_equal "2", Backend.worker_env(1, 3)["TEST_ENV_NUMBER"]
    assert_equal "3", Backend.worker_env(2, 3)["TEST_ENV_NUMBER"]
  end

  def test_a_single_client_run_declares_one_group
    assert_equal "1", Backend.worker_env(0, 1)["PARALLEL_TEST_GROUPS"]
  end

  def test_shared_database_is_fatal_and_the_message_shows_the_fix
    error = assert_raises(Mutineer::DaemonBootError) do
      Backend.assert_distinct_databases!([Fake.new("app_test"), Fake.new("app_test")])
    end

    assert_includes error.message, '"app_test"'
    assert_includes error.message, "<%= ENV['TEST_ENV_NUMBER'] %>"
    assert_includes error.message, "rake parallel:setup"
    assert_includes error.message, "`--jobs` defaults to the number of CPUs"
    assert_includes error.message, "db:create db:schema:load"
  end

  def test_the_guard_finds_a_duplicate_among_distinct_names
    assert_raises(Mutineer::DaemonBootError) do
      Backend.assert_distinct_databases!([Fake.new("a"), Fake.new("b"), Fake.new("a")])
    end
  end

  def test_distinct_databases_pass
    assert_nil Backend.assert_distinct_databases!([Fake.new("app_test"), Fake.new("app_test2")])
  end

  def test_sqlite_workers_report_no_database_and_are_skipped
    assert_nil Backend.assert_distinct_databases!([Fake.new(nil), Fake.new(nil)])
  end

  def test_a_single_worker_never_trips_the_guard
    assert_nil Backend.assert_distinct_databases!([Fake.new("app_test")])
  end
end
