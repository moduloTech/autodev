# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# The environment `mr-review` is handed (Autodev #77).
#
# Regression test for one line of production evidence — the `dc_stderr` of
# powerpanne request 15205 carried a backtrace through
#
#   /opt/homebrew/Cellar/autodev/1.0.0-alpha.47/libexec/vendor/bundle/ruby/
#     4.0.0/gems/gitlab-5.1.0/lib/gitlab/request.rb:71
#
# i.e. `mr-review` loaded the `gitlab` gem out of *autodev's* vendored bundle.
# It is a `bundler/inline` script with its own `gemfile(true)`: resolving there
# means installing its own dependencies into a directory `brew upgrade autodev`
# deletes.
#
# The cause is not `mr-review`'s. autodev is installed with `path: vendor/bundle`
# in deployment mode, and Bundler rewrites `GEM_HOME` / `GEM_PATH` *in the
# process environment* (measured in production: `GEM_HOME=.../libexec/vendor/
# bundle/ruby/4.0.0`, `GEM_PATH=""`). `DangerClaudeRunner::CLEAN_ENV` neutralised
# every `BUNDLE_*` var but neither of those two, so the child inherited them.
#
# What is pinned here is the reviewer's own call path down to `Process.spawn`:
# an external tool must resolve its gems as if it had been launched from a
# terminal. `test/process_runner_test.rb` pins the same property one level down,
# where both callers (`danger-claude` and `mr-review`) pass.
class MrReviewEnvironmentTest < Minitest::Test
  include DatabaseTestHelper

  # Host for the mr-review call path only — the full PipelineMonitor pulls in far
  # more than this needs.
  class Harness
    include DangerClaudeRunner
    include PipelineMonitor::Reviewer

    def initialize(issue:, logger:)
      init_runner(client: nil, config: {}, project_config: { 'path' => 'group/project' },
                  logger: logger, token: 'tok')
      @dc_issue = issue
    end
  end

  # Raised from the stubbed spawn: the environment hash is everything this test
  # wants, so there is no reason to pay for a real child process.
  class SpawnReached < StandardError; end

  MR_URL = 'https://gitlab.example/group/project/-/merge_requests/1'

  def setup
    setup_database
    @issue = create_issue(status: 'reviewing')
    @harness = Harness.new(issue: @issue, logger: StubLogger.new)
  end

  # Runs the real reviewer path and answers the env hash the child would get.
  def spawned_env
    env = nil
    capture = lambda do |spawn_env, *_args, **_opts|
      env = spawn_env
      raise SpawnReached
    end

    Process.stub(:spawn, capture) do
      assert_raises(SpawnReached) { @harness.send(:run_mr_review_command, MR_URL) }
    end
    env
  end

  def test_gem_home_is_unset_for_the_child
    env = spawned_env

    assert_includes env, 'GEM_HOME', 'GEM_HOME must be named in the child environment to be unset'
    assert_nil env['GEM_HOME'], "a nil value is what Process.spawn reads as 'unset this variable'"
  end

  def test_gem_path_is_unset_for_the_child
    env = spawned_env

    assert_includes env, 'GEM_PATH'
    assert_nil env['GEM_PATH']
  end

  # The bundler half of the same contract, already in place before #77 and worth
  # keeping under the same guard: unsetting GEM_HOME without BUNDLE_GEMFILE (or
  # the reverse) leaves the child half-inside autodev's bundle.
  def test_the_bundler_variables_stay_unset_too
    env = spawned_env

    assert(%w[BUNDLE_GEMFILE BUNDLE_PATH RUBYOPT RUBYLIB].all? { |var| env.key?(var) && env[var].nil? },
           "expected every bundler var to be unset, got #{env.inspect}")
  end
end
