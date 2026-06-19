# frozen_string_literal: true

require_relative 'test_helper'

class ConfigLoadTest < Minitest::Test
  def test_defaults_applied
    config = Config.load('config_path' => '/nonexistent/path.yml')

    assert_equal 300, config['poll_interval']
    assert_equal 3, config['max_workers']
  end

  def test_new_defaults_applied
    config = Config.load('config_path' => '/nonexistent/path.yml')

    assert_equal 600, config['pickup_delay']
    assert_equal 5, config['stagnation_threshold']
  end

  def test_yaml_overrides_defaults
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('poll_interval' => 60, 'projects' => [{ 'path' => 'g/p' }]))
      config = Config.load('config_path' => path)

      assert_equal 60, config['poll_interval']
    end
  end

  # IGNORED_GLOBAL_FIELDS (pickup_delay, dc_timeout, database_url, …) are no
  # longer read from the YAML — they keep their baked default and warn.
  def test_ignored_global_field_keeps_its_default
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('pickup_delay' => 120, 'projects' => []))
      config = nil
      capture_io { config = Config.load('config_path' => path) }

      assert_equal 600, config['pickup_delay']
    end
  end

  def test_ignored_global_field_warns
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('dc_timeout' => 999, 'projects' => []))
      err = capture_io { Config.load('config_path' => path) }.last

      assert_match(/DEPRECATION.*dc_timeout/, err)
    end
  end

  def test_web_enabled_is_ignored_and_warns
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('web' => { 'enabled' => false, 'port' => 4567 }, 'projects' => []))
      config = nil
      err = capture_io { config = Config.load('config_path' => path) }.last

      refute config['web'].key?('enabled')
      assert_match(/DEPRECATION.*web\.enabled/, err)
    end
  end

  def test_env_overrides_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('gitlab_token' => 'from_yaml', 'projects' => []))
      ENV['GITLAB_API_TOKEN'] = 'from_env'
      config = Config.load('config_path' => path)

      assert_equal 'from_env', config['gitlab_token']
    end
  ensure
    ENV.delete('GITLAB_API_TOKEN')
  end

  def test_cli_overrides_env
    ENV['GITLAB_API_TOKEN'] = 'from_env'
    config = Config.load('config_path' => '/nonexistent', 'gitlab_token' => 'from_cli')

    assert_equal 'from_cli', config['gitlab_token']
  ensure
    ENV.delete('GITLAB_API_TOKEN')
  end

  def test_numeric_coercion
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('poll_interval' => '120', 'projects' => []))
      config = Config.load('config_path' => path)

      assert_equal 120, config['poll_interval']
      assert_kind_of Integer, config['poll_interval']
    end
  end
end
