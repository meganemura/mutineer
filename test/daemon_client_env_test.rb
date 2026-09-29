# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"

# The environment a daemon is spawned with decides its database: database.yml is
# evaluated at boot, so TEST_ENV_NUMBER has to be in place at spawn. These tests
# call the private builder directly; no daemon is started.
class DaemonClientEnvTest < Minitest::Test
  def test_extra_env_is_merged_into_the_spawn_environment
    env = client(env: { "TEST_ENV_NUMBER" => "2", "PARALLEL_TEST_GROUPS" => "3" }).send(:app_env)

    assert_equal "2", env["TEST_ENV_NUMBER"]
    assert_equal "3", env["PARALLEL_TEST_GROUPS"]
  end

  def test_an_empty_test_env_number_is_passed_through_as_empty
    env = client(env: { "TEST_ENV_NUMBER" => "" }).send(:app_env)

    assert_equal "", env["TEST_ENV_NUMBER"]
  end

  def test_extra_env_wins_over_the_inherited_environment
    with_env("TEST_ENV_NUMBER" => "9") do
      env = client(env: { "TEST_ENV_NUMBER" => "" }).send(:app_env)

      assert_equal "", env["TEST_ENV_NUMBER"]
    end
  end

  def test_bundler_context_is_still_stripped_and_the_app_gemfile_is_set
    with_env("BUNDLE_GEMFILE" => "/elsewhere/Gemfile", "GEM_HOME" => "/elsewhere") do
      env = client(env: { "TEST_ENV_NUMBER" => "2" }).send(:app_env)

      assert_equal "/app/Gemfile", env["BUNDLE_GEMFILE"]
      refute env.key?("GEM_HOME")
    end
  end

  def test_database_is_nil_until_a_handshake_reports_one
    assert_nil client.database
  end

  private

  def client(env: {})
    Mutineer::DaemonClient.new(boot: { rails: true }, app_root: "/app", env: env)
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
