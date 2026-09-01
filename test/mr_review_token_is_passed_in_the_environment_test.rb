# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# How the GitLab credential reaches `mr-review` (Autodev #80).
#
# Until now it did not: `ProcessRunner#spawn_process` hands every child
# `DangerClaudeRunner::CLEAN_ENV`, which only *unsets* things, and the invocation
# carries no token in argv either. `mr-review` was left to find its own in
# `~/.mr-review/config.yml` — a file in another tool's directory, last written on
# 14 April 2026, world-readable, and belonging to nobody's checklist. The token in
# it was revoked that same month and every review through the binary failed for
# four months.
#
# So autodev exports it, `mr_review_token` first and `gitlab_token` otherwise:
# sharing by default, separation only as a decision written down in autodev's own
# configuration rather than as a file somebody forgot.
#
# **In the environment, never in argv.** `mr-review` accepts `-t TOKEN`, and argv
# is readable through `ps` by every account on the machine for the whole run — up
# to an hour for one review. Autodev #10 already dealt with a PAT leaking out of
# this repository once.
#
# And only for this call. CLEAN_ENV is shared by every subprocess autodev starts
# (`danger-claude`, the post-completion commands); the credential is not.
class MrReviewTokenIsPassedInTheEnvironmentTest < Minitest::Test
  include DatabaseTestHelper

  class Harness
    include DangerClaudeRunner
    include PipelineMonitor::Reviewer

    def initialize(issue:, logger:, config: {})
      init_runner(client: nil, config: config, project_config: { 'path' => 'group/project' },
                  logger: logger, token: config['gitlab_token'])
      @dc_issue = issue
    end
  end

  # Deliberately not shaped like a real credential. Nothing here asserts the
  # shape — these two only have to be followed from a config key to a spawn's
  # environment, and to be absent from its argv — and a `glpat-`-shaped literal
  # costs a permanent argument with every secret scanner that reads this repo.
  # GitHub's push protection blocked the alpha-50 release over the previous
  # value, correctly: it matched the pattern, and no scanner can know it was
  # invented. `Redactor::GITLAB_TOKEN` is what covers the real prefixes, and it
  # is exercised where scrubbing is the subject, not here.
  AUTODEV_TOKEN = 'autodev-credential-for-this-test'
  SEPARATE_TOKEN = 'mr-review-credential-for-this-test'
  MR_URL = 'https://gitlab.example/group/project/-/merge_requests/1'
  ENV_VAR = 'GITLAB_API_TOKEN'

  def setup
    setup_database
    @issue = create_issue(status: 'reviewing')
  end

  # The invocation, as `Process.spawn` would see it.
  def spawn_for(config)
    harness = Harness.new(issue: @issue, logger: StubLogger.new, config: config)
    calls = []
    harness.define_singleton_method(:run_with_timeout) do |cmd, args, **opts|
      calls << { cmd: cmd, args: args, opts: opts }
      ['', '', true]
    end
    harness.send(:run_mr_review_command, MR_URL)
    calls.first
  end

  # --- which credential ----------------------------------------------------

  def test_the_shared_token_travels_in_the_environment
    call = spawn_for('gitlab_token' => AUTODEV_TOKEN)

    assert_equal AUTODEV_TOKEN, call[:opts][:env][ENV_VAR]
  end

  def test_a_declared_mr_review_token_wins
    call = spawn_for('gitlab_token' => AUTODEV_TOKEN, 'mr_review_token' => SEPARATE_TOKEN)

    assert_equal SEPARATE_TOKEN, call[:opts][:env][ENV_VAR]
  end

  # A present-and-blank value is a typo, not a separation — the same reading
  # `review_skill` gets everywhere else in the product.
  def test_a_blank_mr_review_token_is_not_a_separation
    call = spawn_for('gitlab_token' => AUTODEV_TOKEN, 'mr_review_token' => '   ')

    assert_equal AUTODEV_TOKEN, call[:opts][:env][ENV_VAR]
  end

  # Exporting an empty value would be worse than exporting nothing: mr-review's
  # own resolution puts the environment *above* its configuration file, so a
  # blank would override a credential that works.
  def test_with_no_credential_at_all_nothing_is_exported
    call = spawn_for({})

    refute_includes call[:opts][:env].keys, ENV_VAR
  end

  # --- never in argv -------------------------------------------------------

  def test_the_command_line_is_unchanged
    call = spawn_for('gitlab_token' => AUTODEV_TOKEN)

    assert_equal ['mr-review', ['-H', MR_URL]], [call[:cmd], call[:args]]
  end

  def test_no_credential_appears_anywhere_in_argv
    call = spawn_for('gitlab_token' => AUTODEV_TOKEN, 'mr_review_token' => SEPARATE_TOKEN)
    command_line = [call[:cmd], *call[:args]].join(' ')

    refute_includes command_line, SEPARATE_TOKEN
    refute_includes command_line, AUTODEV_TOKEN
  end

  # --- and only for this child ---------------------------------------------

  # Measured in the child rather than asserted on a hash: this is the property
  # `env:` exists for, and the same way Autodev #77 pinned CLEAN_ENV.
  ECHO_SCRIPT = "printf '%s' \"${GITLAB_API_TOKEN-unset}\""

  class SpawnHarness
    include ProcessRunner

    def initialize
      @project_config = {}
      @config = {}
      @dc_stdout = +''
      @dc_stderr = +''
    end
  end

  # The developer's own environment must not decide the answer either way.
  def without_the_variable
    previous = ENV.fetch(ENV_VAR, nil)
    ENV.delete(ENV_VAR)
    yield
  ensure
    ENV[ENV_VAR] = previous
  end

  def child_output(**)
    without_the_variable do
      SpawnHarness.new.send(:run_with_timeout, '/bin/sh', ['-c', ECHO_SCRIPT],
                            chdir: Dir.tmpdir, timeout: 30, **).first
    end
  end

  def test_the_child_really_receives_the_exported_credential
    assert_equal AUTODEV_TOKEN, child_output(env: { ENV_VAR => AUTODEV_TOKEN })
  end

  def test_a_caller_that_exports_nothing_leaves_the_child_without_it
    assert_equal 'unset', child_output
  end
end
