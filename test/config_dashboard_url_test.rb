# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #124: `dashboard_url` is the base of the link the activity note
# carries to the issue's page. Unset is a defined state (no link, no error);
# set, it must be an http(s) URL, and the join never produces `//`.
class ConfigDashboardUrlTest < Minitest::Test
  BASE = {
    'gitlab_token' => 'glpat-xxxx', 'poll_interval' => 300, 'max_workers' => 3,
    'dc_timeout' => 1800, 'max_retries' => 3, 'retry_backoff' => 30,
    'pickup_delay' => 600, 'stagnation_threshold' => 5, 'log_level' => 'INFO'
  }.freeze

  OWNER_VALUE = 'https://autodev.netbird.modulotech.fr/'

  # -- Config.dashboard_issue_url --

  def test_a_trailing_slash_does_not_produce_a_double_slash
    assert_equal 'https://autodev.netbird.modulotech.fr/issues/160',
                 Config.dashboard_issue_url({ 'dashboard_url' => OWNER_VALUE }, 160)
  end

  def test_several_trailing_slashes_collapse
    assert_equal 'https://a.example/issues/7',
                 Config.dashboard_issue_url({ 'dashboard_url' => 'https://a.example///' }, 7)
  end

  def test_a_base_without_trailing_slash_gets_one_separator
    assert_equal 'https://a.example/issues/7', Config.dashboard_issue_url({ 'dashboard_url' => 'https://a.example' }, 7)
  end

  def test_a_path_prefix_is_kept
    assert_equal 'https://a.example/autodev/issues/7',
                 Config.dashboard_issue_url({ 'dashboard_url' => 'https://a.example/autodev/' }, 7)
  end

  def test_surrounding_whitespace_is_ignored
    assert_equal 'https://a.example/issues/7',
                 Config.dashboard_issue_url({ 'dashboard_url' => " https://a.example/ \n" }, 7)
  end

  def test_unset_blank_or_not_a_string_answers_nil
    [{}, { 'dashboard_url' => nil }, { 'dashboard_url' => '  ' }, { 'dashboard_url' => 42 }, nil].each do |config|
      assert_nil Config.dashboard_issue_url(config, 7), config.inspect
    end
  end

  def test_no_issue_id_answers_nil
    assert_nil Config.dashboard_issue_url({ 'dashboard_url' => OWNER_VALUE }, nil)
  end

  def test_the_default_is_unset
    assert Config::DEFAULTS.key?('dashboard_url')
    assert_nil Config::DEFAULTS['dashboard_url']
  end

  def test_config_load_reads_the_key_and_defaults_it_to_nil
    Dir.mktmpdir do |dir|
      set = File.join(dir, 'set.yml')
      File.write(set, "gitlab_token: t\ndashboard_url: https://a.example/\n")
      unset = File.join(dir, 'unset.yml')
      File.write(unset, "gitlab_token: t\n")

      assert_equal 'https://a.example/issues/7', Config.dashboard_issue_url(Config.load('config_path' => set), 7)
      assert_nil Config.load('config_path' => unset)['dashboard_url']
    end
  end

  # `bin/autodev` writes TEMPLATE verbatim as a new install's config: the
  # owner's value is an example there, never a setting.
  def test_the_template_documents_the_key_commented_out
    assert_match(/^\s*#\s*dashboard_url: https:/, Config::TEMPLATE)
    refute YAML.safe_load(Config::TEMPLATE).key?('dashboard_url')
  end

  # -- ConfigValidator --

  def test_unset_passes_validation
    ConfigValidator.validate_globals!(BASE)
    ConfigValidator.validate_globals!(BASE.merge('dashboard_url' => nil))
  end

  def test_http_and_https_pass_validation
    ConfigValidator.validate_globals!(BASE.merge('dashboard_url' => OWNER_VALUE))
    ConfigValidator.validate_globals!(BASE.merge('dashboard_url' => 'http://127.0.0.1:4567'))
    ConfigValidator.validate_globals!(BASE.merge('dashboard_url' => " https://a.example/ \n"))
  end

  def test_invalid_values_are_refused_naming_the_key
    ['', '   ', 'autodev.local', 'ftp://a.example/', 'https://', 'https:///issues', 42, ['https://a.example'],
     'https://a example/', 'https://admin:s3cret@a.example/', 'https://a.example/?token=abc',
     'https://a.example/#top', 'https://a.example/?', 'https://a.example/x)y', 'https://a.example/(x'].each do |value|
      error = assert_raises(ConfigError, value.inspect) do
        ConfigValidator.validate_globals!(BASE.merge('dashboard_url' => value))
      end
      assert_includes error.message, 'dashboard_url'
    end
  end
end
