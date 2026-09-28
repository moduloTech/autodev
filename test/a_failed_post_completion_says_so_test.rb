# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'post_completion_fixtures'

# Autodev #94. A failure of the `post_completion` command changes no verdict —
# the delivery happened, the row stays `done` and unflagged — but it is no longer
# silent: every cause stores the error AND posts one comment on the ticket. What
# that comment carries is `test/the_post_completion_comment_says_what_it_may_test.rb`.
class AFailedPostCompletionSaysSoTest < Minitest::Test
  include DatabaseTestHelper
  include PostCompletionFailureFixtures

  def test_a_non_zero_exit_is_stored_and_said_on_the_ticket
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    assert_match(/exited 3/, @issue.reload.post_completion_error)
    assert_equal 1, comments.size
    assert_includes comments.first, 'exited with code 3'
  end

  # ...and a failure is a signal, never a verdict: no give-up flag (#94 item 2).

  def test_a_timeout_is_stored_and_said_on_the_ticket
    monitor(timeout: 1).run_post_completion(@issue, ['sh', '-c', 'sleep 30'])

    assert_match(/timed out after 1s/, @issue.reload.post_completion_error)
    assert_equal 1, comments.size
    assert_includes comments.first, 'after 1 s'
  end

  def test_a_failed_clone_is_stored_and_said_and_does_not_raise
    failing = ->(_dir, _branch) { raise GitError, 'Command failed: git clone' }
    monitor(clone: failing).run_post_completion(@issue, ['bin/deploy'])

    assert_match(%r{could not clone feat/x}, @issue.reload.post_completion_error)
    assert_equal 1, comments.size
    assert_includes comments.first, '`feat/x`'
  end

  def test_an_invalid_command_is_stored_and_said_on_the_ticket
    monitor.run_post_completion(@issue, 'bin/deploy')

    assert_match(/must be an array of strings/, @issue.reload.post_completion_error)
    assert_equal 1, comments.size
    assert_includes comments.first, 'not a list of strings'
  end

  # Adversarial review: both reach `Process.spawn` as an `ArgumentError`.

  def test_an_empty_or_nul_bearing_command_is_stored_and_said
    [[], ["bin/de\0ploy"]].each { |cmd| monitor.run_post_completion(@issue, cmd) }

    assert_equal 2, comments.size
    assert_match(/could not start: ArgumentError/, @issue.reload.post_completion_error)
  end

  # Plan review: `Process.spawn` raises before any exit status exists, so the

  # likeliest misconfiguration of all reached neither handler.

  def test_a_missing_command_is_stored_and_said_and_does_not_raise
    monitor.run_post_completion(@issue, ['bin/does-not-exist'])

    assert_match(/could not start: Errno::ENOENT/, @issue.reload.post_completion_error)
    assert_equal 1, comments.size
    assert_includes comments.first, 'could not be started'
  end

  def test_a_command_that_is_not_executable_is_stored_and_said
    # A script that exists and would succeed, written without its execute bit.
    clone = ->(dir, _) { FileUtils.mkdir_p("#{dir}/bin") && File.write("#{dir}/bin/deploy", "#!/bin/sh\n") }
    monitor(clone: clone).run_post_completion(@issue, ['bin/deploy'])

    assert_match(/Errno::EACCES/, @issue.reload.post_completion_error)
    assert_equal 1, comments.size
  end

  # A signal leaves no exit code: the comment must name the signal, not read

  # "exited with code .".

  def test_a_command_killed_by_a_signal_names_the_signal
    monitor.run_post_completion(@issue, ['sh', '-c', 'kill -9 $$'])

    assert_match(/killed by SIGKILL/, @issue.reload.post_completion_error)
    assert_includes comments.first, 'killed by SIGKILL'
    refute_includes comments.first, 'code .'
  end

  def test_a_success_says_nothing_and_stores_nothing
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 0'])

    assert_nil @issue.reload.post_completion_error
    assert_empty comments
  end

  # The dashboard keeps the output; the ticket does not get it.

  # Concurrency review: a Reset landing while the hook runs lifts the reservation

  # and the error; the old delivery's failure must not be written back, nor said.

  def test_a_reset_during_the_hook_keeps_the_failure_off_the_reset_row
    row = Issue.where(id: @issue.id) # the clone runs with the monitor as `self`
    reset = ->(dir, _) { FileUtils.mkdir_p(dir) && Issue.reset_for_retry!(row, reset_budget: true) }
    monitor(clone: reset).run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    assert_nil @issue.reload.post_completion_error
    assert_empty comments
  end
end
