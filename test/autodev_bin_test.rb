# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Tests for parse_args (bin/autodev CLI argument parsing).
class ParseArgsTest < Minitest::Test
  def test_once_flag
    config = parse_args(['--once'])

    assert config['once']
  end

  def test_dry_run_implies_once
    config = parse_args(['--dry-run'])

    assert config['dry_run']
    assert config['once']
  end

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

  def test_database_url_override
    config = parse_args(['-d', 'sqlite:///tmp/test.db'])

    assert_equal 'sqlite:///tmp/test.db', config['database_url']
  end

  def test_combined_flags
    config = parse_args(['--once', '-n', '2', '-i', '30'])

    assert config['once']
    assert_equal 2, config['max_workers']
    assert_equal 30, config['poll_interval']
  end
end
