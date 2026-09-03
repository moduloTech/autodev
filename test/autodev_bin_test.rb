# frozen_string_literal: true

require_relative 'autodev_test_helper'
require 'autodev/boot_guard'

# Tests for parse_args (bin/autodev CLI argument parsing).
class ParseArgsTest < Minitest::Test
  # --once and --dry-run flags were retired in step 2 second half — the
  # threaded poller they relied on is gone. The one-shot equivalent is
  # `bin/rails runner 'AutodevPollJob.perform_now'`.

  def test_status_flag
    config = parse_args(['--status'])

    assert config['status']
  end

  def test_errors_flag_without_iid
    config = parse_args(['--errors'])

    assert config['errors']
    assert_nil config['errors_iid']
  end

  def test_errors_flag_with_iid
    config = parse_args(['--errors', '15712'])

    assert config['errors']
    assert_equal 15_712, config['errors_iid']
  end

  def test_reset_flag_without_iid
    config = parse_args(['--reset'])

    assert config['reset']
    assert_nil config['reset_iid']
  end

  def test_reset_flag_with_iid
    config = parse_args(['--reset', '42'])

    assert config['reset']
    assert_equal 42, config['reset_iid']
  end

  def test_custom_config_path
    config = parse_args(['-c', '/tmp/custom.yml'])

    assert_equal '/tmp/custom.yml', config['_config_path']
  end

  def test_token_override
    config = parse_args(['-t', 'glpat-test123'])

    assert_equal 'glpat-test123', config['gitlab_token']
  end

  def test_max_workers_override
    config = parse_args(['-n', '5'])

    assert_equal 5, config['max_workers']
  end

  def test_interval_override
    config = parse_args(['-i', '60'])

    assert_equal 60, config['poll_interval']
  end

  def test_combined_flags
    config = parse_args(['-n', '2', '-i', '30'])

    assert_equal 2, config['max_workers']
    assert_equal 30, config['poll_interval']
  end

  # === Ops CLI flags (alpha.7+) ============================================
  # These mirror the lib/tasks/autodev.rake helpers — both delegate to
  # `Autodev::OpsCommands` so behaviour stays identical.

  def test_seed_admin_flag_captures_email
    config = parse_args(['--seed-admin', 'marc@modulotech.fr'])

    assert config['seed_admin']
    assert_equal 'marc@modulotech.fr', config['seed_admin_email']
  end

  def test_sync_memberships_flag
    config = parse_args(['--sync-memberships'])

    assert config['sync_memberships']
  end

  def test_link_user_flag_splits_email_and_username
    config = parse_args(['--link-user', 'marc@modulotech.fr,mleclercq'])

    assert config['link_user']
    assert_equal 'marc@modulotech.fr',     config['link_user_email']
    assert_equal 'mleclercq',              config['link_user_username']
  end
end

# Autodev #92 design §5: `run_boot_guard` is the wiring between bin/autodev
# and Autodev::BootGuard — the db path (AUTODEV_DB, or the same default
# config/database.yml falls back to) and the CLI locale, then `.call`. The
# guard's own classification logic (recognised orphan vs. unrecognised
# holder vs. nothing) is covered end to end in test/boot_guard_test.rb; this
# only pins that bin/autodev actually invokes it with the right arguments.
class RunBootGuardTest < Minitest::Test
  def teardown
    ENV.delete('AUTODEV_DB')
  end

  def test_wires_the_db_path_and_locale_and_calls_the_guard
    ENV['AUTODEV_DB'] = '/tmp/fixture-autodev/autodev.db'
    config = parse_args([])
    logger = Object.new
    captured = {}

    Autodev::BootGuard.stub(:new, capturing_new(captured)) { run_boot_guard(config, logger) }

    assert_equal '/tmp/fixture-autodev/autodev.db', captured[:kwargs][:db_path]
    assert_equal logger, captured[:kwargs][:logger]
    assert captured[:called], 'run_boot_guard must call the guard it builds'
  end

  def test_defaults_the_db_path_when_autodev_db_is_unset
    config = parse_args([])
    logger = Object.new
    captured = {}

    Autodev::BootGuard.stub(:new, capturing_new(captured)) { run_boot_guard(config, logger) }

    assert_equal File.expand_path('~/.autodev/autodev.db'), captured[:kwargs][:db_path]
  end

  private

  # A stand-in for Autodev::BootGuard.new: records the kwargs it was built
  # with into `captured[:kwargs]`, and returns a double whose #call flips
  # `captured[:called]` — enough to assert both the wiring and that
  # run_boot_guard actually invokes the guard it builds.
  def capturing_new(captured)
    fake_guard = Object.new
    fake_guard.define_singleton_method(:call) { captured[:called] = true }
    lambda do |**kwargs|
      captured[:kwargs] = kwargs
      fake_guard
    end
  end
end
