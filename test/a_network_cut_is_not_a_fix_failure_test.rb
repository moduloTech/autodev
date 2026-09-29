# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/mr_fixer'
require 'autodev/pipeline_monitor'
require 'autodev/issue_processor'
require 'autodev/poll_router'

# Autodev #125 — a network cut to GitLab during a fix round is not a fix failure.
#
# `execute_fix_cycle` and `attempt_fix` already let an `ApiUnavailableError`
# through to the round's boundary, which leaves the row for the next cycle. But
# a transport failure only becomes one when the call goes through
# `GitlabHelpers.answer`, and several calls under those two rounds guarded
# themselves with `rescue Gitlab::Error::ResponseError` — which does not catch
# `Net::OpenTimeout`. The cut reached `rescue StandardError`: `error`, and a
# public comment declaring the correction failed. Measured in production on
# A#139 (`resolve_merge_request_discussion`), A#144 and A#136 (`issue_links`).
#
# Each call is fixed where it is, by the kind of call it is (spec, D1): a read
# raises `ApiUnavailableError`, a non-verdict write owned by the round answers
# what actually happened, and what a round announces after it has moved the row
# goes through `IssueNotifier#after_conclusion`.
module NetworkCutFixtures
  FakePipeline = Struct.new(:id, :status)
  FakeMr = Struct.new(:state, :head_pipeline, :target_branch)
  FakeNote = Struct.new(:resolvable, :resolved, :body, :author, :created_at, :position, :system)
  FakeDiscussion = Struct.new(:id, :notes)
  FakeIssuePayload = Struct.new(:iid, :title, :description, :state, :labels)
  FakeUser = Struct.new(:id, :username)
  FakeLink = Struct.new(:iid, :title, :state)
  HandbackIssue = Struct.new(:issue_iid, :displaced_assignee_id, :issue_author_id) do
    # `IssueNotifier#handback_target` asks the row since Autodev #126; the rule
    # is `Issue#handback_target`'s.
    def handback_target = displaced_assignee_id || issue_author_id
  end
  RetriggerIssue = Struct.new(:issue_iid, :pipeline_retrigger_count) do
    # Answers like `ActiveRecord#update` on a row that saved.
    def update(**attrs) = attrs.each { |name, value| self[name] = value } && true
  end

  # Duplicated from `test/api_failure_is_not_a_verdict_test.rb` rather than
  # shared: every test file has to pass run on its own (Autodev #64).
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
  end

  # The whole transport family, one instance of each shape production can throw
  # at us (spec, "Frozen contract").
  CUTS = [Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ECONNREFUSED, Net::OpenTimeout,
          Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError, EOFError].freeze
  # The members of `CUTS` that fail before a request is sent.
  NOT_SENT = [Errno::EHOSTUNREACH, Errno::ECONNREFUSED, Net::OpenTimeout, SocketError].freeze

  SUCCESS_NOTICE = /\A:wrench:/
  CODE_JOBS = [{ 'id' => 51, 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
                 'allow_failure' => false, 'failure_reason' => 'script_failure' }].freeze

  def not_found
    Gitlab::Error::NotFound.new(
      FakeResponse.new('404 Not found', 404, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  # Dated well before any round of this file, so a verdict reached by a round is
  # always newer than the review comment it answers.
  REVIEWED_AT = '2026-01-01T00:00:00Z'

  def thread(id) = FakeDiscussion.new(id, [FakeNote.new(true, false, "please fix #{id}", nil, REVIEWED_AT)])

  def server_error
    Gitlab::Error::InternalServerError.new(
      FakeResponse.new('500 Internal Server Error', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  # Every GitLab call the two rounds make, each answering until `fail` names it.
  # `fail[:create_issue_note]` is a pair `[pattern, error]`, so a test can cut
  # one notice and let the others through — the error note most of all, whose
  # presence is the symptom under test.
  class ScriptedClient
    attr_reader :notes, :resolved, :edits, :retries
    attr_accessor :fail

    def initialize(threads: [], fail: {})
      @threads = threads
      @fail = fail
      @notes = []
      @resolved = []
      @edits = []
      @retries = 0
    end

    # A resolved thread leaves the list, as it does on GitLab, so a round that
    # follows another reads what the previous one left open.
    def merge_request_discussions(_path, _iid, **_opts)
      FakePaginated.new(@threads.reject { |t| @resolved.include?(t.id) })
    end

    def issue_notes(_path, _iid, **_opts) = FakePaginated.new([])
    def pipeline_jobs(_path, _pid, **_opts) = CODE_JOBS
    def user = FakeUser.new(1, 'autodev')

    def merge_request(_path, _iid)
      FakeMr.new('opened', FakePipeline.new(9, 'failed'), 'main')
    end

    def issue(_path, iid)
      trip(:issue)
      FakeIssuePayload.new(iid, 'Le formulaire refuse les accents', 'body', 'opened', ['Doing'])
    end

    def issue_links(_path, _iid)
      trip(:issue_links)
      [FakeLink.new(7, 'Sibling', 'opened')]
    end

    def resolve_merge_request_discussion(_path, _mr_iid, thread_id, **_opts)
      error = @fail[:resolve]
      raise error.last if error && error.first == thread_id

      @resolved << thread_id
    end

    def create_issue_note(_path, _iid, body)
      pattern, error = @fail[:create_issue_note]
      raise error if pattern&.match?(body)

      @notes << body
    end

    def edit_issue(_path, iid, **opts)
      trip(:edit_issue)
      @edits << [iid, opts]
    end

    def retry_pipeline(_path, _pid)
      trip(:retry_pipeline)
      @retries += 1
    end

    def job_trace(_path, _jid)
      trip(:job_trace)
      'the trace'
    end

    private

    def trip(name)
      error = @fail[name]
      raise error if error
    end
  end

  def silence(worker, sink)
    worker.define_singleton_method(:log) { |*| nil }
    worker.define_singleton_method(:log_error) { |msg| sink[:errors] << msg }
    worker.define_singleton_method(:log_activity) { |_i, key, **vars| sink[:activity] << [key, vars] }
  end

  def configure(worker, client, project_config = {})
    { client: client, project_path: 'group/project', project_config: project_config,
      config: {}, logger: StubLogger.new, dc_stdout: '', dc_stderr: '' }
      .each { |name, value| worker.instance_variable_set(:"@#{name}", value) }
  end

  def new_sink = { errors: [], activity: [] }
end

# --- 1-3, 11: the MR discussion round --------------------------------------

# A real row in `fixing_discussions` and a real `MrFixer`, shared by the cut
# tests and their controls.
module MrFixRoundHarness
  include NetworkCutFixtures

  def fixing_row
    issue = create_issue(status: 'pending', mr_iid: 42, mr_url: 'http://gitlab/mr/42',
                         branch_name: 'autodev/2', review_count: 1)
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!
    issue
  end

  # Stubbed: the clone, the rebase, the danger-claude calls and the push. Real:
  # the round, the prompt-context read, the resolution, the notices and the
  # error handler — everything that talks to GitLab. The verification is off
  # (`fix_verification_max: 0`): this file is about GitLab, not about #79.
  def fixer(client, stubs = {}, project_config = UNVERIFIED)
    MrFixer.allocate.tap do |fix|
      configure(fix, client, project_config)
      silence(fix, @sink)
      local_steps.merge(stubs).each { |name, body| fix.define_singleton_method(name) { |*, **| body.call } }
    end
  end

  def local_steps
    { clone_and_checkout: -> {}, rebase_branch_on_target: -> {}, default_branch: -> { 'main' },
      detect_agent: -> {}, format_discussion: -> { 'thread body' }, run_fix_prompt: -> {},
      danger_claude_commit: -> {}, new_commits?: -> { true }, push_fixes: -> {} }
  end

  UNVERIFIED = { 'fix_verification_max' => 0 }.freeze

  def run_round(issue, client, stubs = {}, project_config = UNVERIFIED)
    SkillsInjector.stub(:inject, { all_skills: [] }) { fixer(client, stubs, project_config).fix(issue) }
    issue.reload
  end

  def error_notes(client) = client.notes.grep(/echec correction MR/)

  def success_notice(client)
    notices = client.notes.grep(SUCCESS_NOTICE)

    assert_equal 1, notices.size, 'one success notice per round'
    notices.first
  end
end

class MrFixRoundNetworkCutTest < Minitest::Test
  include MrFixRoundHarness
  include DatabaseTestHelper

  def setup
    setup_database
    @sink = new_sink
  end

  # 1. A#144: the `issue_links` read under the prompt context timed out.
  def test_an_issue_links_cut_leaves_the_round_for_the_next_cycle
    client = ScriptedClient.new(threads: [thread('t1')], fail: { issue_links: Net::OpenTimeout.new })
    issue = run_round(fixing_row, client)

    assert_equal ['fixing_discussions', nil, 0], [issue.status, issue.error_message, issue.fix_round],
                 'a round that could not read its context is not an attempt, and not a failure'
    assert_empty error_notes(client), 'no comment may blame the correction for a network cut'
    assert(@sink[:errors].any? { |m| m.include?('issue_links') }, 'the boundary log names the endpoint')
  end

  # ... and the next cycle is the replay: the same row, GitLab answering, runs
  # the correction through to the pipeline watch.
  def test_the_next_cycle_replays_the_round
    issue = fixing_row
    client = ScriptedClient.new(threads: [thread('t1')], fail: { issue_links: Net::OpenTimeout.new })
    run_round(issue, client)
    client.fail = {}

    run_round(issue, client)

    assert_equal 'checking_pipeline', issue.status
    assert_equal 1, issue.fix_round
    assert_equal ['t1'], client.resolved
  end

  def test_the_cut_is_an_api_unavailable_error_named_issue_links
    client = ScriptedClient.new(fail: { issue_links: Net::OpenTimeout.new })

    err = assert_raises(ApiUnavailableError) { GitlabHelpers.fetch_full_context(client, 'group/project', 1) }

    assert_equal :issue_links, err.what
    assert_kind_of Net::OpenTimeout, err.cause
  end

  # 2. A#139: one of two verified threads could not be resolved. The round is
  # not a failure, and the success line counts only what GitLab resolved (#79).
  def test_a_resolution_cut_costs_that_thread_and_nothing_else # rubocop:disable Minitest/MultipleAssertions
    client = ScriptedClient.new(threads: [thread('t1'), thread('t2')],
                                fail: { resolve: ['t2', Net::OpenTimeout.new] })
    issue = run_round(fixing_row, client)

    assert_equal ['checking_pipeline', nil], [issue.status, issue.error_message]
    assert_empty error_notes(client)
    assert_equal ['t1'], client.resolved
    assert_match(/: 1 commentaire\(s\)/, success_notice(client), 'the success line counts what GitLab resolved')
  end

  # 3. The push has landed and `discussions_fixed!` has fired; the notice that
  # announces it is the last thing the round does, and it cannot undo it.
  def test_a_cut_on_the_success_notice_does_not_undo_the_pushed_round # rubocop:disable Minitest/MultipleAssertions
    issue = fixing_row
    client = ScriptedClient.new(threads: [thread('t1')],
                                fail: { create_issue_note: [SUCCESS_NOTICE, Net::OpenTimeout.new] })

    run_round(issue, client)

    assert_equal 'checking_pipeline', issue.status
    assert_nil issue.error_message
    assert_empty error_notes(client)
    assert_includes @sink[:activity].map(&:first), :discussions_fixed
  end
end

# 11. Controls: what genuinely is this round's failure still is one.
class MrFixRoundControlTest < Minitest::Test
  include MrFixRoundHarness
  include DatabaseTestHelper

  def setup
    setup_database
    @sink = new_sink
  end

  def test_control_a_danger_claude_failure_still_fails_the_round
    issue = fixing_row
    client = ScriptedClient.new(threads: [thread('t1')])

    run_round(issue, client, run_fix_prompt: -> { raise ImplementationError, 'danger-claude -p failed' })

    assert_equal 'error', issue.status
    assert_equal 1, error_notes(client).size
  end

  def test_control_a_failed_push_still_fails_the_round
    issue = fixing_row
    client = ScriptedClient.new(threads: [thread('t1')])

    run_round(issue, client, push_fixes: -> { raise GitError, 'push rejected' })

    assert_equal 'error', issue.status
    assert_equal 1, error_notes(client).size
  end

  # `Errno::ENOENT` is a `SystemCallError`, a member of the transport family by
  # class. Raised by the clone it is a missing binary or directory, and must not
  # read as "GitLab is down" — which is why no boundary-level net was added.
  def test_control_a_local_system_call_error_is_still_a_fix_failure
    issue = fixing_row
    client = ScriptedClient.new(threads: [thread('t1')])

    run_round(issue, client, clone_and_checkout: -> { raise Errno::ENOENT, 'git' })

    assert_equal 'error', issue.status
    assert_equal 1, error_notes(client).size
    refute(@sink[:errors].any? { |m| m.include?('did not answer') })
  end
end

# --- Amendment 1: resolutions after the push, and remembered ---------------

# Shared by the two classes below: verified rounds over a scripted GitLab.
module PendingResolutionHarness
  include NetworkCutFixtures

  # Verification on, with a threshold low enough that the stagnation the
  # blocker led to is two rounds away.
  VERIFIED = { 'fix_verification_max' => 10, 'stagnation_threshold' => 2 }.freeze
  DIFF = "diff --git a/app/x.rb b/app/x.rb\n+  guard_clause\n"

  def setup
    setup_database
    @sink = new_sink
    @dc_calls = []
  end

  # `diff` is what each correction of the round changed, and `commits` whether
  # the round left anything to push. The verification pass says `addressed`
  # whenever it is asked, so an empty diff is the only way to fail it here.
  def verified_round(issue, client, diff:, commits:, **stubs)
    calls = @dc_calls
    addressed = VerificationContract.parse(JSON.generate(verdict: 'addressed', reason: 'the guard was added'))
    steps = { head_sha: -> { 'sha-before' }, correction_diff: -> { diff }, run_verification: -> { addressed },
              new_commits?: -> { commits }, run_fix_prompt: -> { calls << :fix } }
    run_round(issue, client, steps.merge(stubs), VERIFIED)
  end

  def back_to_fixing(issue)
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!
  end

  def cut_t2_then_heal(issue, threads)
    client = ScriptedClient.new(threads: threads, fail: { resolve: ['t2', Net::OpenTimeout.new] })
    verified_round(issue, client, diff: DIFF, commits: true)
    client.fail = {}
    @dc_calls.clear
    client
  end

  def pending(issue) = JSON.parse(issue.pending_resolutions || '{}')

  # A round after the correction reached the branch: nothing left to change.
  def empty_round(issue, client)
    back_to_fixing(issue)
    verified_round(issue, client, diff: '', commits: false)
  end

  def reply_to(discussion)
    discussion.notes << FakeNote.new(true, false, 'still wrong', nil, (Time.now.utc + 60).iso8601)
  end
end

# The adversarial review's blocker. A verified correction whose resolution was
# cut could never be resolved afterwards: the next round found the correction
# already on the branch, measured an empty diff (`:unchanged`), left the thread
# open, and `stagnation_threshold` rounds later gave the request up on a
# stagnation that was really one lost write. And a round that aborted after a
# resolution but before the push left a thread closed over a correction GitLab
# never received.
#
# So the resolutions come after the push, and the one that did not take is
# remembered with the time of its verdict: the next round makes it directly,
# unless somebody wrote on the thread since.
class PendingResolutionTest < Minitest::Test
  include MrFixRoundHarness
  include DatabaseTestHelper
  include PendingResolutionHarness

  # The blocker replay: rounds 2 and 3 find t2's correction already on the
  # branch, an empty diff and nothing to push.
  def test_a_lost_resolution_is_made_at_the_next_round_without_a_fix # rubocop:disable Minitest/MultipleAssertions
    issue = fixing_row
    client = cut_t2_then_heal(issue, [thread('t1'), thread('t2')])

    2.times { empty_round(issue, client) }

    refute_includes @sink[:activity].map(&:first), :stagnation_discussions
    assert_equal 'checking_pipeline', issue.status
    assert_equal %w[t1 t2], client.resolved
    assert_empty @dc_calls, 'the correction is already on the branch: nothing is fixed twice'
    assert_nil issue.pending_resolutions
  end

  def test_a_lost_resolution_is_remembered_with_the_time_of_its_verdict
    before = Time.now.utc.floor
    issue = fixing_row
    cut_t2_then_heal(issue, [thread('t1'), thread('t2')])

    assert_equal ['t2'], pending(issue).keys
    assert_operator Time.iso8601(pending(issue)['t2']), :>=, before
    assert_includes @sink[:activity], [:discussion_resolution_deferred, { title: 'please fix t2' }]
  end

  # Somebody wrote on the thread after the verdict: the old verdict does not
  # answer what they said, so the thread is read and fixed like any other.
  def test_a_reply_after_the_verdict_is_fixed_normally
    issue = fixing_row
    replied = thread('t2')
    client = cut_t2_then_heal(issue, [thread('t1'), replied])
    reply_to(replied)

    empty_round(issue, client)

    assert_equal [:fix], @dc_calls, 'a reply is read again, not closed on the old verdict'
    assert_equal ['t1'], client.resolved
    assert_nil issue.pending_resolutions
  end

  # GitLab still does not take it: it stays remembered, and still nothing is
  # fixed twice.
  def test_a_resolution_lost_twice_stays_remembered
    issue = fixing_row
    client = cut_t2_then_heal(issue, [thread('t1'), thread('t2')])
    remembered = pending(issue)
    client.fail = { resolve: ['t2', Net::OpenTimeout.new] }

    empty_round(issue, client)

    assert_equal remembered, pending(issue)
    assert_empty @dc_calls
    assert_equal 'checking_pipeline', issue.status
  end

  # A thread somebody closed by hand, or deleted, is no longer ours to resolve.
  def test_a_remembered_thread_gitlab_no_longer_lists_is_forgotten
    issue = fixing_row
    client = cut_t2_then_heal(issue, [thread('t1'), thread('t2')])
    client.resolved << 't2'

    empty_round(issue, client)

    assert_nil issue.pending_resolutions
  end

  # The pre-existing defect: resolving inside the loop closed threads whose
  # correction then never reached GitLab.
  def test_nothing_is_resolved_when_the_push_fails
    issue = fixing_row
    client = ScriptedClient.new(threads: [thread('t1')])

    run_round(issue, client, push_fixes: -> { raise GitError, 'push rejected' })

    assert_equal 'error', issue.status
    assert_empty client.resolved, 'a thread may not be closed over a correction that was not pushed'
  end

  # The only thread's resolution was cut: "no correction validated" would be
  # false, and the per-thread entry already says what happened.
  def test_a_lone_lost_resolution_is_not_reported_as_nothing_validated
    client = ScriptedClient.new(threads: [thread('t1')], fail: { resolve: ['t1', Net::OpenTimeout.new] })

    issue = verified_round(fixing_row, client, diff: DIFF, commits: true)
    keys = @sink[:activity].map(&:first)

    assert_includes keys, :discussion_resolution_deferred
    refute_includes keys, :discussions_none_resolved
    assert_equal 'checking_pipeline', issue.status
  end
end

# The branch is rebuilt from scratch on a reimplementation, so a remembered
# verdict about a correction on the old branch no longer holds.
class ReimplementationForgetsPendingResolutionsTest < Minitest::Test
  include DatabaseTestHelper

  FakeGlIssue = Struct.new(:iid, :title)

  def setup = setup_database

  def test_a_reimplementation_clears_the_pending_resolutions
    issue = create_issue(status: 'done', pending_resolutions: JSON.generate('t2' => '2026-09-29T10:00:00Z'))
    router = PollRouter.allocate
    %i[log_activity enqueue_issue_processing].each { |name| router.define_singleton_method(name) { |*| nil } }

    router.send(:reenter_via_reimplementation, FakeGlIssue.new(issue.issue_iid, 'a request'), issue)

    assert_equal 'pending', issue.reload.status
    assert_nil issue.pending_resolutions
  end
end

# --- 4, 5, 11: the pipeline fix round --------------------------------------

class PipelineFixNetworkCutTest < Minitest::Test
  include NetworkCutFixtures
  include DatabaseTestHelper

  def setup
    setup_database
    @sink = new_sink
  end

  def watched_row
    issue = create_issue(status: 'pending', mr_iid: 42, mr_url: 'http://gitlab/mr/42',
                         branch_name: 'autodev/1', issue_author_id: 7, review_count: 1)
    advance_to(issue, 'checking_pipeline')
    issue
  end

  # Stubbed: the clone, the job logs, the pre-triage and the per-job fixes.
  # Real: `check`, the prompt-context read, the push decision, the notices.
  def monitor(client, stubs = {})
    PipelineMonitor.allocate.tap do |mon|
      configure(mon, client)
      silence(mon, @sink)
      {
        claude_available?: -> { true }, pre_triage: -> { { verdict: :code, explanation: 'rspec is red' } },
        prepare_work_dir: -> {}, fix_each_job: -> {}, push_branch: -> {},
        write_and_categorize_jobs: -> { [{ name: 'rspec', category: :test, log_path: '/tmp/rspec.log' }] },
        run_cmd_status: -> { ["abc123 fix rspec\n", '', true] }
      }.merge(stubs).each { |name, body| mon.define_singleton_method(name) { |*, **| body.call } }
    end
  end

  def poll(issue, client, stubs = {})
    monitor(client, stubs).check(issue)
    issue.reload
  end

  def error_notes(client) = client.notes.grep(/echec de la correction du pipeline/)

  # 4. A#136: the same `issue_links` read, under the pipeline fix. It is read
  # before `pipeline_failed_code!` (Autodev #67), so the row is still on the
  # watch when the abort reaches `check`.
  def test_an_issue_links_cut_leaves_the_row_on_the_watch
    issue = watched_row
    client = ScriptedClient.new(fail: { issue_links: Net::OpenTimeout.new })

    poll(issue, client)

    assert_equal 'checking_pipeline', issue.status
    assert_nil issue.error_message
    assert_empty error_notes(client)
  end

  # The row being back on the watch is not enough on its own: a round that fixed
  # and pushed ends there too. So no fix may have been attempted at all — no
  # round counted, nothing pushed, no danger-claude call.
  def test_an_issue_links_cut_attempts_no_fix
    issue = watched_row
    fixes = []

    poll(issue, ScriptedClient.new(fail: { issue_links: Net::OpenTimeout.new }),
         fix_each_job: -> { fixes << :danger_claude })

    assert_equal 0, issue.fix_round
    refute_includes @sink[:activity].map(&:first), :pipeline_fix_pushed
    assert_empty fixes, 'no danger-claude call under a round that could not read its context'
  end

  # 5. The pushed fix went through `pipeline_fix_done!`; the notice is after it.
  def test_a_cut_on_the_success_notice_does_not_undo_the_pushed_fix # rubocop:disable Minitest/MultipleAssertions
    issue = watched_row
    client = ScriptedClient.new(fail: { create_issue_note: [SUCCESS_NOTICE, Net::OpenTimeout.new] })

    poll(issue, client)

    assert_equal 'checking_pipeline', issue.status
    assert_equal 1, issue.fix_round, 'the round went through pipeline_fix_done!'
    assert_nil issue.error_message
    assert_empty error_notes(client)
    assert_includes @sink[:activity].map(&:first), :pipeline_fix_pushed
  end

  # 11. Control, pipeline side: a local failure of the clone is still the fix's.
  # The status is not asserted, and on purpose: the clone runs before
  # `pipeline_failed_code!`, `mark_failed` has no transition out of
  # `checking_pipeline`, and `whiny_transitions: false` makes that a silent
  # no-op — a pre-existing behaviour this ticket does not touch. What is pinned
  # is the reading: the fix handler took it, not the outage boundary.
  def test_control_a_local_system_call_error_is_still_a_fix_failure
    issue = watched_row
    client = ScriptedClient.new

    poll(issue, client, prepare_work_dir: -> { raise Errno::ENOENT, 'git' })

    assert_match(/\APipeline fix error: Errno::ENOENT/, issue.error_message)
    assert_equal 1, error_notes(client).size
    refute(@sink[:errors].any? { |m| m.include?('did not answer') })
  end

  # 8. Amendment 1. A `Net::ReadTimeout` comes after the request was sent, so the
  # retrigger may well have reached GitLab: it is counted as one, and the poll
  # waits for the pipeline it may have started rather than triaging the old one.
  def test_a_retrigger_timeout_counts_as_a_retrigger_and_waits
    issue = watched_row
    client = ScriptedClient.new(fail: { retry_pipeline: Net::ReadTimeout.new })
    reached = []
    mon = monitor(client, pre_triage: -> { { verdict: :uncertain } })
    mon.define_singleton_method(:infra_skip?) { |*| (reached << :infra_skip?) && true }

    mon.send(:triage_and_fix, issue, FakePipeline.new(9, 'failed'), CODE_JOBS)

    assert_equal 1, issue.reload.pipeline_retrigger_count
    assert_empty reached, 'the triage waits for the next poll'
  end

  # A connection that never opened sent nothing — nearly all of production's
  # cuts are `Net::OpenTimeout` — so the one retrigger is not spent on it.
  def test_a_retrigger_that_never_connected_answers_false_and_spends_nothing
    issue = watched_row
    mon = monitor(ScriptedClient.new(fail: { retry_pipeline: Net::OpenTimeout.new }))

    assert_same false, mon.send(:retrigger_if_needed, issue, FakePipeline.new(9, 'failed'), { verdict: :uncertain })
    assert_equal 0, issue.reload.pipeline_retrigger_count
  end

  def test_retrigger_if_needed_answers_true_on_a_timeout
    issue = watched_row
    mon = monitor(ScriptedClient.new(fail: { retry_pipeline: Net::ReadTimeout.new }))

    assert_same true, mon.send(:retrigger_if_needed, issue, FakePipeline.new(9, 'failed'), { verdict: :uncertain })
    assert_equal 1, issue.reload.pipeline_retrigger_count
  end

  # An HTTP answer is GitLab refusing: nothing was retriggered, and the triage
  # it would have skipped runs.
  def test_a_retrigger_refusal_answers_false_and_the_triage_continues
    issue = watched_row
    client = ScriptedClient.new(fail: { retry_pipeline: server_error })
    reached = []
    mon = monitor(client, pre_triage: -> { { verdict: :uncertain } })
    mon.define_singleton_method(:infra_skip?) { |*| (reached << :infra_skip?) && true }

    assert_same false, mon.send(:retrigger_if_needed, issue, FakePipeline.new(9, 'failed'), { verdict: :uncertain })
    mon.send(:triage_and_fix, issue, FakePipeline.new(9, 'failed'), CODE_JOBS)

    assert_equal 0, issue.reload.pipeline_retrigger_count
    assert_equal [:infra_skip?], reached
  end
end

# --- 6, 7: the two prompt-context reads that used to substitute ------------

class PromptReadNetworkCutTest < Minitest::Test
  include NetworkCutFixtures

  def monitor(client)
    PipelineMonitor.allocate.tap do |mon|
      configure(mon, client)
      silence(mon, new_sink)
    end
  end

  # 6. A trace that never arrived is not a trace GitLab refused: the first is
  # the round's to replay, the second is still prose for the prompt.
  def test_a_job_trace_cut_raises_api_unavailable_error
    mon = monitor(ScriptedClient.new(fail: { job_trace: Net::ReadTimeout.new }))

    err = assert_raises(ApiUnavailableError) { mon.send(:fetch_job_trace, CODE_JOBS.first) }

    assert_equal :job_trace, err.what
  end

  def test_a_job_trace_refusal_keeps_its_placeholder_in_gitlabs_words
    refusal = not_found
    mon = monitor(ScriptedClient.new(fail: { job_trace: refusal }))

    trace = mon.send(:fetch_job_trace, CODE_JOBS.first)

    assert_equal "(trace unavailable: #{refusal.message})", trace
    refute_match(/did not answer/, trace)
  end

  def test_control_a_readable_job_trace_is_the_trace
    assert_equal 'the trace', monitor(ScriptedClient.new).send(:fetch_job_trace, CODE_JOBS.first)
  end

  # 7. The capability gap of #67 is still swallowed: an older GitLab has no such
  # endpoint, and a list of sibling titles decides nothing.
  def links_of(client)
    lines = []
    GitlabHelpers::IssueFormatter.append_links(lines, client, 'group/project', 1)
    lines
  end

  def test_a_links_refusal_still_gives_no_section
    assert_empty links_of(ScriptedClient.new(fail: { issue_links: not_found }))
  end

  def test_a_client_without_issue_links_still_gives_no_section
    assert_empty links_of(Object.new)
  end

  def test_an_issue_links_no_method_error_still_gives_no_section
    assert_empty links_of(ScriptedClient.new(fail: { issue_links: NoMethodError.new('issue_links') }))
  end

  def test_control_readable_links_give_the_section
    assert_includes links_of(ScriptedClient.new), '## Related issues'
  end
end

# --- 9, 10, 12: the writes owned by the round ------------------------------

class RoundWritesNetworkCutTest < Minitest::Test
  include NetworkCutFixtures
  include DatabaseTestHelper

  LABELS = { 'labels_todo' => ['To Do'], 'label_doing' => 'Doing', 'label_done' => 'Done',
             'label_attention' => 'Attention' }.freeze

  def setup
    setup_database
    @sink = new_sink
  end

  def worker(klass, client, project_config = {})
    klass.allocate.tap do |w|
      configure(w, client, project_config)
      silence(w, @sink)
    end
  end

  def handback_issue = HandbackIssue.new(12, nil, 7)

  # 9. The abandon notice claims a handback only when there was one (#60).
  def test_a_handback_cut_answers_false
    [Net::OpenTimeout.new, Errno::ECONNREFUSED.new].each do |cut|
      fix = worker(MrFixer, ScriptedClient.new(fail: { edit_issue: cut }))

      assert_same false, fix.send(:hand_ticket_back, handback_issue), cut.class.name
    end
  end

  def test_an_abandon_after_a_handback_cut_does_not_claim_the_handback
    issue = create_issue(status: 'pending', mr_iid: 42, mr_url: 'http://gitlab/mr/42', issue_author_id: 7)
    advance_to(issue, 'checking_pipeline')
    client = ScriptedClient.new(fail: { edit_issue: Net::OpenTimeout.new })

    worker(PipelineMonitor, client).send(:abandon_issue, issue, :stagnation_pipeline, detail: 'rspec')

    assert_equal 1, client.notes.size
    refute_match(/reassigne le ticket/, client.notes.first)
  end

  # 12. `abandon!` is the verdict; the label and the notice announce it.
  def test_an_abandon_survives_a_cut_on_the_label_write
    issue = abandoned_with(fail: { issue: Net::OpenTimeout.new })

    assert_equal 'done', issue.status
    assert issue.needs_attention
  end

  def test_an_abandon_survives_a_cut_on_the_notice
    issue = abandoned_with(fail: { create_issue_note: [/./, Net::OpenTimeout.new] })

    assert_equal 'done', issue.status
    assert issue.needs_attention
    assert_includes @sink[:activity].map(&:first), :stagnation_pipeline
  end

  def abandoned_with(fail:)
    issue = create_issue(status: 'pending', mr_iid: 42, mr_url: 'http://gitlab/mr/42', issue_author_id: 7)
    advance_to(issue, 'checking_pipeline')
    mon = worker(PipelineMonitor, ScriptedClient.new(fail: fail), LABELS)

    assert mon.send(:abandon_issue, issue, :stagnation_pipeline, detail: 'rspec')
    issue.reload
  end

  # 10. The whole family, on each of the four, each answering its contracted
  # value — and a programming error still travelling as itself from each. The
  # retrigger answers by whether the request can have reached GitLab: `false`
  # for a connection that never opened, `true` (counted as sent) for the rest.
  def four_writes
    { resolve_discussion: [false, method(:resolve_under)], hand_ticket_back: [false, method(:hand_back_under)],
      retrigger_if_needed: [->(klass) { !NOT_SENT.include?(klass) }, method(:retrigger_under)],
      after_conclusion: [nil, method(:conclude_under)] }
  end

  def resolve_under(cut)
    worker(MrFixer, ScriptedClient.new(fail: { resolve: ['t1', cut] })).send(:resolve_discussion, 42, 't1')
  end

  def hand_back_under(cut)
    worker(MrFixer, ScriptedClient.new(fail: { edit_issue: cut })).send(:hand_ticket_back, handback_issue)
  end

  def retrigger_under(cut)
    mon = worker(PipelineMonitor, ScriptedClient.new(fail: { retry_pipeline: cut }))
    mon.send(:retrigger_if_needed, RetriggerIssue.new(12, 0), FakePipeline.new(9, 'failed'), { verdict: :uncertain })
  end

  def conclude_under(cut)
    worker(MrFixer, ScriptedClient.new).send(:after_conclusion, :x) { raise cut }
  end

  def test_the_whole_transport_family_is_swallowed_by_each_write
    four_writes.each do |name, (expected, call)|
      CUTS.each do |klass|
        result = call.call(klass.new)
        want = expected.respond_to?(:call) ? expected.call(klass) : expected

        want.nil? ? assert_nil(result, "#{name} on #{klass}") : assert_same(want, result, "#{name} on #{klass}")
      end
    end
  end

  def test_a_programming_error_still_propagates_from_each_write
    four_writes.each do |name, (_expected, call)|
      assert_raises(NoMethodError, name.to_s) { call.call(NoMethodError.new('undefined method')) }
    end
  end

  # The contract's other half: the block's own value, and a log line naming it.
  def test_after_conclusion_returns_the_blocks_value
    assert_equal 42, worker(MrFixer, ScriptedClient.new).send(:after_conclusion, :x) { 42 }
  end

  def test_after_conclusion_logs_what_it_lost_and_why
    worker(MrFixer, ScriptedClient.new).send(:after_conclusion, :mr_fix_success) { raise Net::OpenTimeout, 'slow' }

    line = @sink[:errors].last

    assert_includes line, 'mr_fix_success'
    assert_includes line, 'Net::OpenTimeout: slow'
  end

  # 11. Control: `notify_issue` is deliberately unchanged. It is how an answer is
  # delivered, and the transition right after it must not fire on a cut.
  def test_control_a_cut_answer_is_not_marked_answered
    issue = create_issue(status: 'pending')
    advance_to(issue, 'checking_spec')
    issue.question_detected!
    client = ScriptedClient.new(fail: { create_issue_note: [/./, Net::OpenTimeout.new] })

    assert_raises(Net::OpenTimeout) do
      worker(IssueProcessor, client).send(:post_answer, issue.issue_iid, issue, 'the answer')
    end
    assert_equal 'answering_question', issue.reload.status
  end
end

# The bound on a remembered resolution GitLab keeps refusing.
class PendingResolutionBoundTest < Minitest::Test
  include MrFixRoundHarness
  include DatabaseTestHelper
  include PendingResolutionHarness

  # GitLab's own "changed this line in version N of the diff" note lands on the
  # thread at the push that follows the verdict; it is not somebody replying.
  def test_a_system_note_after_the_verdict_is_not_a_reply
    issue = fixing_row
    threads = [thread('t1'), thread('t2')]
    client = cut_t2_then_heal(issue, threads)
    threads.last.notes << FakeNote.new(true, false, 'changed this line in version 2 of the diff', nil,
                                       (Time.now.utc + 60).iso8601, nil, true)

    empty_round(issue, client)

    assert_equal [%w[t1 t2], [], 'checking_pipeline'], [client.resolved, @dc_calls, issue.status]
  end

  # A remembered resolution refused again is said, not reported as "nothing to fix".
  def test_a_resolution_lost_again_is_said
    issue = fixing_row
    client = cut_t2_then_heal(issue, [thread('t1'), thread('t2')])
    client.fail = { resolve: ['t2', Net::OpenTimeout.new] }
    @sink[:activity].clear

    empty_round(issue, client)

    assert_includes @sink[:activity].map(&:first), :discussion_resolution_deferred
  end

  # A note whose time cannot be read counts as a reply: fixed again, not closed.
  def test_an_unreadable_note_time_counts_as_a_reply
    issue = fixing_row
    threads = [thread('t1'), thread('t2')]
    client = cut_t2_then_heal(issue, threads)
    threads.last.notes << FakeNote.new(true, false, 'hm', nil, 'not a time', nil, nil)

    empty_round(issue, client)

    assert_equal [:fix], @dc_calls
  end

  # A column that does not hold a JSON object reads as nothing remembered.
  def test_an_unreadable_column_reads_as_nothing_remembered
    issue = fixing_row
    issue.update(pending_resolutions: '[not json')
    client = ScriptedClient.new(threads: [thread('t1')])

    verified_round(issue, client, diff: DIFF, commits: true)

    assert_equal [%w[t1], 'checking_pipeline'], [client.resolved, issue.status]
  end

  # A resolution GitLab refuses for good (a 403, say) must not loop for ever
  # between `checking_pipeline` and a fix-free round: each round that loses a
  # remembered resolution again counts towards the round ceiling (#99).
  def test_a_resolution_refused_for_good_reaches_the_round_ceiling
    issue = fixing_row
    client = cut_t2_then_heal(issue, [thread('t1'), thread('t2')])
    client.fail = { resolve: ['t2', Net::OpenTimeout.new] }

    rounds = 0
    (rounds += 1) && empty_round(issue, client) until issue.status == 'done' || rounds > 20

    assert_equal %w[done fix_rounds_exhausted], [issue.status, issue.attention_reason]
    assert_empty @dc_calls
  end
end
