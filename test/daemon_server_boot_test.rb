# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

# The daemon exits the process on a failed boot (`exit!`), so the handshake is
# checked in a child ruby with a stub ActiveRecord as the "app". No Rails is
# needed: the boot file only defines the few methods RailsWorkerDb calls.
class DaemonServerBootTest < Minitest::Test
  SERVER = File.expand_path("../lib/mutineer/daemon_server.rb", __dir__)

  def test_postgres_boot_reports_the_connected_database
    ready = boot_with(adapter: "postgresql", database: "app_test2")

    assert_equal true, ready["ready"]
    assert_equal "app_test2", ready["database"]
  end

  def test_sqlite_boot_reports_no_database
    ready = boot_with(adapter: "sqlite3", database: "storage/test.sqlite3")

    assert_equal true, ready["ready"]
    assert_nil ready["database"]
  end

  def test_an_unreachable_database_fails_the_handshake
    ready = boot_with(adapter: "postgresql", database: "app_test9", execute_error: "FATAL: database \"app_test9\" does not exist")

    assert_equal false, ready["ready"]
    assert_match(/app_test9.*does not exist/, ready["error"])
  end

  def test_a_missing_driver_gem_fails_the_handshake_instead_of_skipping_the_check
    ["LoadError", "Gem::LoadError"].each do |klass|
      ready = boot_with(adapter: "postgresql", database: "app_test", execute_error: "cannot load such file -- pg",
                        error_class: klass)

      assert_equal false, ready["ready"], klass
      assert_match(/#{klass}: .*pg/, ready["error"])
    end
  end

  private

  BOOT_RB = <<~'RUBY'
    module ActiveRecord
      class Base
        CONFIG = Struct.new(:configuration_hash, :database)
        def self.connection_db_config
          CONFIG.new({ adapter: ENV.fetch("STUB_ADAPTER") }, ENV.fetch("STUB_DATABASE"))
        end

        def self.connection
          self
        end

        def self.execute(_sql)
          raise Object.const_get(ENV.fetch("STUB_ERROR_CLASS", "RuntimeError")), ENV["STUB_ERROR"] if ENV["STUB_ERROR"]
        end
      end
    end
  RUBY

  def boot_with(adapter:, database:, execute_error: nil, error_class: "RuntimeError")
    Dir.mktmpdir do |dir|
      boot = File.join(dir, "boot.rb")
      File.write(boot, BOOT_RB)
      env = { "STUB_ADAPTER" => adapter, "STUB_DATABASE" => database, "STUB_ERROR" => execute_error,
              "STUB_ERROR_CLASS" => error_class }
      payload = { cmd: "boot", project_root: dir, boot: boot, framework: "minitest", rails: true }

      IO.popen(env, [RbConfig.ruby, "-r", SERVER, "-e", "Mutineer::DaemonServer.run"], "r+", err: File::NULL) do |io|
        io.puts JSON.generate(payload)
        line = io.gets
        io.puts JSON.generate(cmd: "quit")
        io.close_write
        JSON.parse(line)
      end
    end
  end
end
