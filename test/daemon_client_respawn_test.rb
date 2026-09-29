# frozen_string_literal: true

require_relative "test_helper"
require "mutineer/daemon_client"
require "json"
require "rbconfig"
require "stringio"
require "tmpdir"

# A respawn must hand the new daemon the same environment as the first one and
# take its database from the new handshake. The daemon is a stand-in `bundle`
# executable found through PATH, so the test needs no Rails and no app bundle.
# The stand-in reports `db<TEST_ENV_NUMBER>_g<PARALLEL_TEST_GROUPS>_spawn<n>` as
# its database, where <n> counts how often it was started, and dies without a
# reply when a payload says `crash`.
class DaemonClientRespawnTest < Minitest::Test
  TOUCHED_ENV = %w[PATH FAKE_DAEMON_DIR RUBYOPT RUBYLIB BUNDLER_SETUP].freeze

  FAKE_BUNDLE = <<~RUBY
    #!#{RbConfig.ruby}
    require "json"
    counter = File.join(ENV.fetch("FAKE_DAEMON_DIR"), "spawns")
    n = (File.exist?(counter) ? File.read(counter).to_i : 0) + 1
    File.write(counter, n.to_s)
    $stdin.gets
    database = "db\#{ENV['TEST_ENV_NUMBER']}_g\#{ENV['PARALLEL_TEST_GROUPS']}_spawn\#{n}"
    puts JSON.generate("ready" => true, "database" => database)
    $stdout.flush
    while (line = $stdin.gets)
      msg = JSON.parse(line)
      exit!(0) if msg["cmd"] == "quit"
      exit!(1) if msg["payload"]["code"] == "crash"
      puts JSON.generate("id" => msg["id"], "verdict" => "killed")
      $stdout.flush
    end
  RUBY

  def test_the_handshake_database_is_read_on_the_first_spawn
    with_fake_daemon do |client|
      assert_equal "db2_g3_spawn1", client.start.database
    end
  end

  def test_a_respawn_keeps_the_env_and_refreshes_the_database
    with_fake_daemon do |client|
      client.start

      assert_equal "error", crash(client, 1), "the in-flight mutant is scored error"
      assert_equal "db2_g3_spawn2", client.database, "the database comes from the new handshake"
      assert_equal "killed", client.request(id: 2, payload: { "code" => "ok" }, tests: [], timeout: 5),
                   "the respawned daemon serves the next mutant"
    end
  end

  def test_each_respawn_refreshes_the_database_again
    with_fake_daemon do |client|
      client.start
      crash(client, 1)
      crash(client, 2)

      assert_equal "db2_g3_spawn3", client.database
    end
  end

  private

  def crash(client, id)
    client.request(id: id, payload: { "code" => "crash" }, tests: [], timeout: 5)
  end

  def with_fake_daemon
    Dir.mktmpdir do |dir|
      bundle = File.join(dir, "bundle")
      File.write(bundle, FAKE_BUNDLE)
      File.chmod(0o755, bundle)
      saved = ENV.to_h.slice(*TOUCHED_ENV)
      # Spawn adds to the parent environment, so under `bundle exec` the child
      # Ruby would inherit `-rbundler/setup`, and the stand-in has no Gemfile.
      %w[RUBYOPT RUBYLIB BUNDLER_SETUP].each { |k| ENV.delete(k) }
      ENV["PATH"] = [dir, ENV.fetch("PATH", nil)].compact.join(File::PATH_SEPARATOR)
      ENV["FAKE_DAEMON_DIR"] = dir
      client = Mutineer::DaemonClient.new(boot: { project_root: dir }, app_root: dir, errio: StringIO.new,
                                          env: { "TEST_ENV_NUMBER" => "2", "PARALLEL_TEST_GROUPS" => "3" })
      begin
        yield client
      ensure
        client.quit
      end
    ensure
      TOUCHED_ENV.each { |k| saved&.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
    end
  end
end
