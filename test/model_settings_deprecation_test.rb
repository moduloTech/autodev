# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Autodev #122. The global and per-project `model` / `effort` settings are
# deprecated: they keep being read (see
# test/the_spec_check_runs_on_the_default_model_test.rb) until they are
# removed, and setting either is signalled at boot. Production sets both
# globally (`model: "claude-opus-4-7"`, `effort: "xhigh"`) and neither on a
# project, so the global half is the one that fires today.
class ModelSettingsDeprecationTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  def setup
    @logger = StubLogger.new
    @pastel = FakePastel.new
    @config = { 'web' => { 'locale' => 'fr' } }
  end

  def found(config, projects = [])
    Config.deprecated_model_settings(config, projects)
  end

  def test_the_two_deprecated_keys
    assert_equal %w[model effort], Config::DEPRECATED_MODEL_SETTINGS
  end

  def test_nothing_set_finds_nothing
    assert_empty found({ 'poll_interval' => 120 }, [{ 'path' => 'g/p' }])
  end

  def test_a_global_setting_is_found_with_its_value
    assert_equal [{ scope: 'global', field: 'model', value: 'claude-opus-4-7' }],
                 found({ 'model' => 'claude-opus-4-7' })
  end

  def test_a_project_setting_is_found_under_its_path
    assert_equal [{ scope: 'g/p', field: 'effort', value: 'high' }],
                 found({}, [{ 'path' => 'g/p', 'effort' => 'high' }])
  end

  def test_globals_come_first_then_projects_in_order
    result = found({ 'effort' => 'xhigh', 'model' => 'm' },
                   [{ 'path' => 'z/z', 'model' => 'x' }, { 'path' => 'a/a', 'effort' => 'low' }])

    pairs = result.map { |f| [f[:scope], f[:field]] }

    assert_equal [%w[global model], %w[global effort], %w[z/z model], %w[a/a effort]], pairs
  end

  # An empty form field is stored blank, not as a choice of model.
  def test_a_blank_value_is_not_a_setting
    assert_empty found({ 'model' => '' }, [{ 'path' => 'g/p', 'model' => nil, 'effort' => '  ' }])
  end

  def test_the_boot_warning_is_silent_when_nothing_is_set
    warn_model_setting_deprecations([], @config, @logger, @pastel)

    assert_empty @logger.messages
  end

  def test_the_boot_warning_names_the_global_setting_and_its_value
    warn_model_setting_deprecations(found('model' => 'claude-opus-4-7'), @config, @logger, @pastel)
    output = @logger.messages.join("\n")

    assert_includes output, 'model'
    assert_includes output, 'claude-opus-4-7'
    assert_includes output, 'config.yml'
  end

  def test_the_boot_warning_names_the_project
    warn_model_setting_deprecations(found({}, [{ 'path' => 'group/proj', 'effort' => 'high' }]),
                                    @config, @logger, @pastel)
    output = @logger.messages.join("\n")

    assert_includes output, 'group/proj'
    assert_includes output, "'effort' = high"
  end

  def test_one_line_per_setting_plus_a_header
    warn_model_setting_deprecations(found({ 'model' => 'm', 'effort' => 'e' }, [{ 'path' => 'g/p', 'model' => 'x' }]),
                                    @config, @logger, @pastel)

    assert_equal 4, @logger.messages.size
    assert_includes @logger.messages.first, '3'
  end

  def test_the_warning_says_the_settings_will_be_removed
    warn_model_setting_deprecations(found('model' => 'm'), @config, @logger, @pastel)

    assert_includes @logger.messages.first, 'supprim'
  end

  def test_the_warning_follows_the_configured_ui_locale
    warn_model_setting_deprecations(found('model' => 'm'), { 'web' => { 'locale' => 'en' } }, @logger, @pastel)

    assert_includes @logger.messages.first, 'deprecated'
  end

  # The entry point reads the `projects` table: a database it cannot read must
  # cost the warning, never the boot (same rule as the numeric-settings audit).
  def test_an_unreadable_projects_table_costs_the_warning_not_the_boot
    Project.stub(:runtime_configs, ->(_) { raise ActiveRecord::StatementInvalid, 'locked' }) do
      warn_deprecated_model_settings({ 'model' => 'm' }, @logger, @pastel)
    end

    assert(@logger.messages.any? { |m| m.include?('locked') })
  end

  def test_the_entry_point_reads_global_and_project_settings
    Project.stub(:runtime_configs, ->(_) { [{ 'path' => 'g/p', 'effort' => 'high' }] }) do
      warn_deprecated_model_settings(@config.merge('model' => 'm'), @logger, @pastel)
    end
    output = @logger.messages.join("\n")

    assert_includes output, 'g/p'
    assert_includes output, 'm'
    assert_equal 3, @logger.messages.size
  end

  # Deprecated is not ignored: config.yml's two keys survive `Config.load`. The
  # codebase's other deprecation list, `IGNORED_GLOBAL_FIELDS`, drops what it
  # names — putting `model` there would switch production's setting off.
  def test_config_load_keeps_both_settings_and_does_not_call_them_ignored
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('model' => 'claude-opus-4-7', 'effort' => 'xhigh', 'projects' => []))
      config = nil
      err = capture_io { config = Config.load('config_path' => path) }.last

      assert_equal 'claude-opus-4-7', config['model']
      assert_equal 'xhigh', config['effort']
      refute_match(/no longer read.*(model|effort)/, err)
    end
  end

  # The warning is only worth something if the boot runs it.
  def test_bootstrap_runs_the_warning
    noop = %i[offer_template_config validate_config setup_database warn_rejected_numeric_settings
              setup_chrome_devtools warn_dev_recurring_disabled warn_stub_azure_credentials]
    stubs = noop.to_h { |name| [name, ->(*) {}] }
    with_toplevel_stubs(stubs) do
      Project.stub(:runtime_configs, ->(_) { [] }) do
        bootstrap(@config.merge('model' => 'm', 'log_level' => 'INFO'), BootLogger.new(@logger), @pastel)
      end
    end

    header = Locales.t(:cli_model_settings_deprecated_header, locale: :fr, count: 1)

    assert(@logger.messages.any? { |m| m.include?(header) })
  end

  # `bootstrap` also configures the logger it is handed.
  class BootLogger < SimpleDelegator
    def configure(**) = nil
  end

  # bin/autodev's methods are private methods of Object, so `bootstrap` sends
  # its steps to the receiver it runs on — this test instance.
  def with_toplevel_stubs(stubs)
    stubs.each { |name, impl| define_singleton_method(name, &impl) }
    yield
  ensure
    stubs.each_key { |name| singleton_class.send(:remove_method, name) }
  end
end
