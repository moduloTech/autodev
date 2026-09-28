# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #94. A failure of the `post_completion` command changes no verdict —
# the delivery happened, the row stays `done` and unflagged — but it is no longer
# silent: every failure path stores the error AND posts one comment on the ticket,
# saying which command failed and how, and never what it printed.
#
# The command is really spawned (a `sh -c` in a temp dir); only the clone is
# stubbed, because it is the one step that needs a GitLab remote.
class AFailedPostCompletionSaysSoTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  SECRET = 'glpat-SECRETSECRETSECRET'
  # What the command prints, assembled by `printf` so that the command's own text
  # (which the comment does carry) never contains it.
  MARKER = 'MARKER-OUTPUT'
  PRINTS_MARKER = "printf '%s-%s' MARKER OUTPUT"

  class RecordingClient
    attr_reader :notes

    def initialize = @notes = []

    def create_issue_note(_project, iid, body) = @notes << [iid, body]
  end

  def setup
    setup_database
    @client = RecordingClient.new
    @issue = create_issue(project_path: PATH, status: 'done', mr_iid: 42, branch_name: 'feat/x',
                          mr_url: 'https://gitlab.example/group/project/-/merge_requests/42', locale: 'en')
  end

  def monitor(timeout: 60, clone: ->(dir, _branch) { FileUtils.mkdir_p(dir) })
    PipelineMonitor.new(client: @client, config: { 'gitlab_url' => 'https://gitlab.example' },
                        project_config: { 'path' => PATH, 'post_completion_timeout' => timeout },
                        logger: StubLogger.new, token: 'x').tap do |m|
      m.define_singleton_method(:clone_and_checkout, &clone)
    end
  end

  def comments = @client.notes.map(&:last)

  def test_a_non_zero_exit_is_stored_and_said_on_the_ticket
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    assert_match(/exited 3/, @issue.reload.post_completion_error)
    assert_equal 1, comments.size
    assert_includes comments.first, 'exited with code 3'
  end

  def test_the_comment_names_the_command_and_the_merge_request
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    assert_includes comments.first, '`sh -c exit 3`'
    assert_includes comments.first, @issue.mr_url
  end

  def test_the_comment_says_the_delivery_stands_and_how_to_replay
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 1'])

    assert_includes comments.first, Locales.t(:post_completion_failed_footer, locale: :en)
  end

  def test_the_comment_follows_the_ticket_locale
    @issue.update!(locale: 'fr')
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    assert_includes comments.first, 'termin' # "s'est terminee avec le code 3"
    assert_includes comments.first, Locales.t(:post_completion_failed_footer, locale: :fr)
  end

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
  def test_the_comment_never_carries_the_command_output
    monitor.run_post_completion(@issue, ['sh', '-c', "#{PRINTS_MARKER}; #{PRINTS_MARKER} >&2; exit 2"])

    assert_includes @issue.reload.post_completion_error, "stdout: #{MARKER}"
    assert_includes @issue.post_completion_error, "stderr: #{MARKER}"
    refute_includes comments.first, MARKER
  end

  def test_the_command_is_scrubbed_before_it_is_published
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 4', "https://oauth2:#{SECRET}@gitlab.example/x.git"])

    assert_equal 1, comments.size
    refute_includes comments.first, SECRET
  end

  # A failure is a signal, never a verdict: no give-up flag (Autodev #94 item 2).
  def test_a_failure_leaves_the_row_delivered
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    refute_predicate @issue.reload, :needs_attention
    assert_equal 'done', @issue.status
  end
end
