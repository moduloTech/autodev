# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/worker_pool'
require 'stringio'

# Provide Pastel as FakePastel so bin/autodev methods work without the real gem.
Pastel = Class.new(FakePastel) unless defined?(Pastel) # rubocop:disable Naming/ConstantName

# Load methods and constants from bin/autodev without executing gemfile() or main.
autodev_src = File.read(File.expand_path('../bin/autodev', __dir__), encoding: 'utf-8')
# Strip the gemfile block, require lines (already loaded), and the trailing main call.
stripped = autodev_src
           .sub(/^gemfile.*?^end\n/m, '')
           .gsub(/^require(?:_relative)?\s.*$/, '')
           .gsub(/^I18n\..*$/, '')
           .sub(/^main\s*$/, '')
eval(stripped, TOPLEVEL_BINDING, 'bin/autodev', 1) # rubocop:disable Security/Eval

# Mixin that stubs Database.connect/build_model! so in-memory DB survives method calls.
module StubDatabaseConnect
  def setup
    super
    Database.define_singleton_method(:connect) { |_url| true }
    Database.define_singleton_method(:build_model!) { nil }
  end

  def teardown
    Database.singleton_class.remove_method(:connect)
    Database.singleton_class.remove_method(:build_model!)
    super
  end
end

# ===========================================================================
# status_label
# ===========================================================================
class StatusLabelTest < Minitest::Test
  def test_active_states_return_en_cours
    %w[cloning implementing reviewing checking_pipeline].each do |s|
      assert_equal 'En cours', status_label(s), "Expected 'En cours' for #{s}"
    end
  end

  def test_pending
    assert_equal 'En attente', status_label('pending')
  end

  def test_needs_clarification
    assert_equal 'En attente de clarification', status_label('needs_clarification')
  end

  def test_over
    assert_equal 'Terminée', status_label('over')
  end

  def test_blocked
    assert_equal 'Bloquée', status_label('blocked')
  end

  def test_error
    assert_equal 'Erreur', status_label('error')
  end

  def test_unknown_status_returns_itself
    assert_equal 'banana', status_label('banana')
  end
end

# ===========================================================================
# show_dashboard
# ===========================================================================
class ShowDashboardTest < Minitest::Test
  include DatabaseTestHelper
  include StubDatabaseConnect

  def setup
    setup_database
    super
  end

  def test_no_issues_message
    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_dashboard(config) }.first

    assert_match(/Aucune issue active/, out)
  end

  def test_no_issues_with_all_flag
    config = { 'database_url' => 'sqlite://:memory:', 'status_all' => true }
    out = capture_io { show_dashboard(config) }.first

    assert_match(/Aucune issue suivie/, out)
  end

  def test_dashboard_shows_issues
    create_issue(issue_iid: 100, issue_title: 'Fix the bug', project_path: 'group/myapp', status: 'pending')
    create_issue(issue_iid: 101, issue_title: 'Add feature', project_path: 'group/myapp', status: 'implementing')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_dashboard(config) }.first

    assert_match(/#100/, out)
    assert_match(/#101/, out)
    assert_match(/Fix the bug/, out)
    assert_match(/pending/, out)
    assert_match(/implementing/, out)
    assert_match(/2 active/, out)
  end

  def test_dashboard_excludes_over_by_default
    create_issue(issue_iid: 200, issue_title: 'Done issue', project_path: 'group/project', status: 'over')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_dashboard(config) }.first

    refute_match(/#200/, out)
  end

  def test_dashboard_includes_over_with_all_flag
    create_issue(issue_iid: 201, issue_title: 'Done issue', project_path: 'group/project', status: 'over')

    config = { 'database_url' => 'sqlite://:memory:', 'status_all' => true }
    out = capture_io { show_dashboard(config) }.first

    assert_match(/#201/, out)
    assert_match(/over/, out)
  end

  def test_dashboard_shows_error_excerpt
    create_issue(issue_iid: 300, issue_title: 'Broken', project_path: 'group/proj',
                 status: 'error', error_message: "RuntimeError: something went wrong\nbacktrace here")

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_dashboard(config) }.first

    assert_match(/RuntimeError/, out)
  end

  def test_dashboard_truncates_long_title
    create_issue(issue_iid: 400, issue_title: 'A' * 50, project_path: 'group/proj', status: 'pending')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_dashboard(config) }.first

    # Title should be truncated with ellipsis
    assert_match(/A{37}…/, out)
  end

  def test_dashboard_shows_mr_info
    create_issue(issue_iid: 500, issue_title: 'With MR', project_path: 'group/proj',
                 status: 'implementing', mr_iid: 42, mr_url: 'https://gitlab.example.com/mr/42')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_dashboard(config) }.first

    assert_match(/MR !42/, out)
  end

  def test_dashboard_shows_hidden_count
    create_issue(issue_iid: 600, issue_title: 'Completed', project_path: 'group/project', status: 'over')
    create_issue(issue_iid: 601, issue_title: 'Active', status: 'pending')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_dashboard(config) }.first

    assert_match(/terminées masquées/, out)
  end
end

# ===========================================================================
# show_errors
# ===========================================================================
class ShowErrorsTest < Minitest::Test
  include DatabaseTestHelper
  include StubDatabaseConnect

  def setup
    setup_database
    super
  end

  def test_no_errors_message
    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_errors(config) }.first

    assert_match(/Aucune issue en erreur/, out)
  end

  def test_no_errors_for_specific_iid
    config = { 'database_url' => 'sqlite://:memory:', 'errors_iid' => 999 }
    out = capture_io { show_errors(config) }.first

    assert_match(/Issue #999 non trouvée/, out)
  end

  def test_shows_error_issue
    create_issue(issue_iid: 700, issue_title: 'Broken build', project_path: 'group/proj',
                 status: 'error', error_message: "NoMethodError: undefined method 'foo'",
                 retry_count: 2, branch_name: 'autodev/fix-700')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_errors(config) }.first

    assert_match(/#700/, out)
    assert_match(/Broken build/, out)
    assert_match(/NoMethodError/, out)
    assert_match(/Tentative: 2/, out)
    assert_match(/autodev\/fix-700/, out)
  end

  def test_shows_blocked_issue
    create_issue(issue_iid: 701, issue_title: 'Blocked thing', project_path: 'group/proj',
                 status: 'blocked', error_message: 'Pipeline infra failure')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_errors(config) }.first

    assert_match(/#701/, out)
    assert_match(/blocked/, out)
    # blocked issues don't show retry count
    refute_match(/Tentative/, out)
  end

  def test_shows_stderr
    create_issue(issue_iid: 702, issue_title: 'With stderr', project_path: 'group/proj',
                 status: 'error', error_message: 'Failed', dc_stderr: "warning: something\nerror line")

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_errors(config) }.first

    assert_match(/stderr/, out)
    assert_match(/warning: something/, out)
  end

  def test_filters_by_iid
    create_issue(issue_iid: 710, issue_title: 'Error A', project_path: 'group/proj',
                 status: 'error', error_message: 'fail A')
    create_issue(issue_iid: 711, issue_title: 'Error B', project_path: 'group/proj',
                 status: 'error', error_message: 'fail B')

    config = { 'database_url' => 'sqlite://:memory:', 'errors_iid' => 711 }
    out = capture_io { show_errors(config) }.first

    refute_match(/#710/, out)
    assert_match(/#711/, out)
  end

  def test_shows_post_completion_errors
    create_issue(issue_iid: 720, issue_title: 'PC error', project_path: 'group/proj',
                 status: 'over', post_completion_error: 'deploy script failed')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_errors(config) }.first

    assert_match(/#720/, out)
    assert_match(/post_completion/, out)
    assert_match(/deploy script failed/, out)
  end

  def test_shows_mr_info_on_error
    create_issue(issue_iid: 730, issue_title: 'MR error', project_path: 'group/proj',
                 status: 'error', error_message: 'fail', mr_iid: 55, mr_url: 'https://example.com/mr/55')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { show_errors(config) }.first

    assert_match(/!55/, out)
  end
end

# ===========================================================================
# reset_errors
# ===========================================================================
class ResetErrorsTest < Minitest::Test
  include DatabaseTestHelper
  include StubDatabaseConnect

  def setup
    setup_database
    super
    @pastel = FakePastel.new
  end

  def test_no_errors_to_reset
    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { reset_errors(config, @pastel) }.first

    assert_match(/Aucune issue en erreur/, out)
  end

  def test_no_errors_for_specific_iid
    config = { 'database_url' => 'sqlite://:memory:', 'reset_iid' => 999 }
    out = capture_io { reset_errors(config, @pastel) }.first

    assert_match(/Issue #999 non trouvée/, out)
  end

  def test_resets_all_errors
    create_issue(issue_iid: 800, status: 'error', error_message: 'fail1', retry_count: 2,
                 next_retry_at: Time.now.to_s)
    create_issue(issue_iid: 801, status: 'error', error_message: 'fail2', retry_count: 1,
                 next_retry_at: Time.now.to_s)

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { reset_errors(config, @pastel) }.first

    assert_match(/2 issue\(s\) remise\(s\) en pending/, out)

    # Verify DB state
    assert_equal 'pending', Issue[issue_iid: 800].status
    assert_equal 0, Issue[issue_iid: 800].retry_count
    assert_nil Issue[issue_iid: 800].error_message
    assert_equal 'pending', Issue[issue_iid: 801].status
  end

  def test_resets_specific_iid
    create_issue(issue_iid: 810, status: 'error', error_message: 'fail', retry_count: 3)
    create_issue(issue_iid: 811, status: 'error', error_message: 'other fail', retry_count: 1)

    config = { 'database_url' => 'sqlite://:memory:', 'reset_iid' => 810 }
    out = capture_io { reset_errors(config, @pastel) }.first

    assert_match(/Issue #810/, out)
    assert_equal 'pending', Issue[issue_iid: 810].status
    # 811 should remain in error
    assert_equal 'error', Issue[issue_iid: 811].status
  end

  def test_does_not_reset_blocked
    create_issue(issue_iid: 820, status: 'blocked', error_message: 'infra')

    config = { 'database_url' => 'sqlite://:memory:' }
    out = capture_io { reset_errors(config, @pastel) }.first

    assert_match(/Aucune issue en erreur/, out)
    assert_equal 'blocked', Issue[issue_iid: 820].status
  end
end

# ===========================================================================
# parse_args
# ===========================================================================
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

# ===========================================================================
# Constants
# ===========================================================================
class AutodevConstantsTest < Minitest::Test
  def test_status_colors_covers_all_states
    all_states = ACTIVE_STATES + %w[pending needs_clarification over blocked error]
    all_states.each do |state|
      assert STATUS_COLORS.key?(state), "STATUS_COLORS missing key '#{state}'"
    end
  end

  def test_status_colors_frozen
    assert STATUS_COLORS.frozen?
  end

  def test_active_states_are_subset_of_status_colors
    ACTIVE_STATES.each do |state|
      assert STATUS_COLORS.key?(state), "ACTIVE_STATES has '#{state}' not in STATUS_COLORS"
    end
  end
end
