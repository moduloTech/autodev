# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/mr_fixer'
require 'autodev/pipeline_monitor'

# Autodev #62 — a GitLab call that failed must not answer with a value.
#
# Autodev #56 fixed one instance of this family (the pipeline age bound firing
# behind a poll that never read a status). Three readers were left taking a
# degraded return value for a verdict, all three built on the same shape:
#
#     rescue Gitlab::Error::ResponseError
#       []            # or nil, or false
#     end
#
# `[]` is not "GitLab is down", it is "nothing was found" — and at every call
# site in this codebase "nothing was found" is the good news:
#
#   1. `fetch_unresolved_discussions` → `[]` reads as a clean MR, and
#      `green_post_review` turns that into the `no_discussions` guard and
#      delivers. An MR carrying unresolved review threads shipped as reviewed
#      because GitLab hiccuped, with no attention flag and no comment — the same
#      outcome as the 11/08/2026 incident, by another route and with nothing to
#      betray it. (It is also a standing candidate for the race
#      `DiscussionSnapshot` was added to chase: issue #11859 went `done` with
#      count = 0 while 12 threads were open.)
#   2. `fetch_failed_jobs` → `[]` reads as "nothing fails anymore", which
#      `InfraRecheck#current_pipeline_verdict` calls `:recovered` and re-arms a
#      row whose pipeline may still be red.
#   3. a danger-claude evaluation that never ran returns nil, the poll ends
#      normally having concluded nothing, and the #56 age bound could fire
#      behind it.
#
# The fix is structural, not per-call-site: `GitlabHelpers.answer` is the single
# conversion point from "GitLab did not answer" to `ApiUnavailableError`, so a
# failed read has no representation as data at all. Nothing is left for a caller
# to misread, the poll ends at the boundary rescue with the row untouched, and
# the *default* for a newly added API call — no rescue at all — is now the safe
# one.
#
# Each section below has its control: the same code path with GitLab answering
# must still reach the verdict it always reached.

# --- shared fixtures -------------------------------------------------------

module ApiFailureFixtures
  FakePipeline = Struct.new(:id, :status)
  FakeMr = Struct.new(:state, :head_pipeline)
  FakeNote = Struct.new(:resolvable, :resolved, :body)
  FakeDiscussion = Struct.new(:id, :notes)

  # Gitlab::Error::ResponseError builds its message from the real HTTP response;
  # this is the minimum surface it reads. The conversion point is narrow on
  # purpose, so a plain Gitlab::Error::Error would not exercise it.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  def api_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  def unresolved_thread
    FakeDiscussion.new('open-thread', [FakeNote.new(true, false, 'please fix this')])
  end

  def resolved_thread
    FakeDiscussion.new('closed-thread', [FakeNote.new(true, true, 'done')])
  end

  # Behaves like Gitlab::PaginatedResponse: the real list is only visible
  # through auto_paginate.
  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
  end

  # A PipelineMonitor with the four collaborators `init_runner` sets, and silent
  # logs. Each section adds the stubs its own path needs on top.
  def bare_monitor(client)
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, client)
    mon.instance_variable_set(:@project_path, 'group/project')
    mon.instance_variable_set(:@project_config, {})
    mon.instance_variable_set(:@config, {})
    %i[log log_error].each { |noop| mon.define_singleton_method(noop) { |*| nil } }
    mon
  end
end

# --- 1. an API error must never deliver an MR ------------------------------

# The gravest of the three: this is the only path whose degraded value ends in a
# delivery. `handle_green` on a post-review MR asks GitLab for the unresolved
# threads, and the answer decides between `done` and `fixing_discussions`.
class ApiFailureNeverDeliversTest < Minitest::Test
  include ApiFailureFixtures
  # `finalize_green_done` stamps `finished_at` through `Issue.where(...)`, so the
  # delivery control needs the real table behind it.
  include DatabaseTestHelper

  def setup = setup_database

  # Mirrors the real AASM machine on the one transition under test: the
  # `pipeline_green` event reads the `no_discussions` guard the caller stamped.
  class FakeIssue
    attr_reader :issue_iid, :mr_iid, :mr_url, :review_count, :issue_author_id,
                :checking_pipeline_since, :pipeline_poll_since, :id
    attr_accessor :_review_count_zero, :_review_count_over_zero, :_unresolved_discussions_empty

    def initialize(review_count: 1)
      @attrs = { status: 'checking_pipeline' }
      @review_count = review_count
      @issue_iid = 11_859
      @mr_iid = 42
      @mr_url = 'http://gitlab/mr/42'
      @issue_author_id = 7
      @checking_pipeline_since = 1.hour.ago
    end

    # rubocop:disable Naming/PredicateMethod -- mirrors AASM's bang event, which
    # returns whether the transition happened.
    def pipeline_green!
      @attrs[:status] = _unresolved_discussions_empty ? 'done' : 'fixing_discussions'
      true
    end
    # rubocop:enable Naming/PredicateMethod

    def update(hash)
      @attrs.merge!(hash)
      @pipeline_poll_since = hash[:pipeline_poll_since] if hash.key?(:pipeline_poll_since)
      @checking_pipeline_since = hash[:checking_pipeline_since] if hash.key?(:checking_pipeline_since)
      self
    end

    def status = @attrs[:status]
    def done? = status == 'done'
  end

  # One open MR with a green head pipeline; the discussions endpoint either
  # answers `threads` or fails the way GitLab fails.
  class StubClient
    attr_reader :discussion_calls

    def initialize(threads: [], error: nil)
      @threads = threads
      @error = error
      @discussion_calls = 0
    end

    def merge_request(_path,
                      _iid)
      ApiFailureFixtures::FakeMr.new('opened',
                                     ApiFailureFixtures::FakePipeline.new(215_229, 'success'))
    end

    def merge_request_discussions(_path, _iid, **_opts)
      @discussion_calls += 1
      raise @error if @error

      ApiFailureFixtures::FakePaginated.new(@threads)
    end
  end

  def poll(threads: [], error: nil)
    client = StubClient.new(threads: threads, error: error)
    sink = { labels: [], notify: [], reassigned: [], activity: [] }
    mon = bare_monitor(client)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:snapshot) { |*| nil }
    stub_sinks(mon, sink)
    issue = FakeIssue.new
    mon.check(issue)
    [issue, sink, client]
  end

  # Every point at which the delivery leaves the process: the GitLab label, the
  # assignee, the issue comment and the activity log.
  def stub_sinks(mon, sink)
    mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:apply_label_done) { |iid| sink[:labels] << iid }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:reassign_to_author) { |issue| sink[:reassigned] << issue.issue_iid }
  end

  # The bug, end to end.
  def test_an_unreachable_discussions_endpoint_does_not_deliver
    issue, sink = poll(error: api_error)

    assert_equal 'checking_pipeline', issue.status, 'an unread discussion list must not deliver the MR'
    assert_empty sink[:labels] + sink[:notify] + sink[:reassigned],
                 'no label, no comment and no handback may follow a read that failed'
  end

  # The row is left exactly where the previous poll left it, activity note
  # included: `dispatch_pipelines` re-enqueues it next cycle, and a line appended
  # per poll would grow the GitLab note for as long as the outage lasts.
  def test_an_unreachable_discussions_endpoint_leaves_no_green_trace
    _issue, sink = poll(error: api_error)

    refute_includes sink[:activity].map(&:first), :pipeline_green
    refute_includes sink[:activity].map(&:first), :pipeline_green_done
  end

  # --- controls: GitLab answering must still reach both verdicts ----------

  def test_no_unresolved_thread_still_delivers
    issue, sink, client = poll(threads: [resolved_thread])

    assert_equal ['done', [11_859], [:done_nominal]],
                 [issue.status, sink[:labels], sink[:notify].map(&:first)]
    assert_equal 1, client.discussion_calls, 'the delivery verdict must be read, not assumed'
  end

  def test_an_unresolved_thread_still_routes_to_the_fixer
    issue, sink = poll(threads: [unresolved_thread])

    assert_equal 'fixing_discussions', issue.status
    assert_empty sink[:labels]
  end
end

# --- 2. an API error must not read as "the CI is back" ---------------------

# `recheck_infra_recovery` re-arms a row that was given up on an infra failure,
# and it re-arms it on `:recovered` — which `current_pipeline_verdict` returns
# for an empty failed-job list. `fetch_failed_jobs` returned exactly that on an
# API error, so a GitLab outage during a recheck read as "nothing fails anymore".
class ApiFailureIsNotARecoveryTest < Minitest::Test
  include ApiFailureFixtures

  class FakeIssue
    ISSUE_IID = 16_081
    MR_IID = 42

    def initialize = (@attrs = { infra_recheck_count: 0 })
    def update(hash) = (@attrs.merge!(hash) and self)
    def issue_iid = ISSUE_IID
    def mr_iid = MR_IID
    def infra_recheck_count = @attrs[:infra_recheck_count]
    def infra_recheck_at = @attrs[:infra_recheck_at]
  end

  class StubClient
    def initialize(jobs: [], error: nil)
      @jobs = jobs
      @error = error
    end

    def merge_request(_path,
                      _iid)
      ApiFailureFixtures::FakeMr.new('opened',
                                     ApiFailureFixtures::FakePipeline.new(9, 'failed'))
    end

    def pipeline_jobs(_path, _pid, **_opts)
      raise @error if @error

      @jobs
    end
  end

  def recheck(jobs: [], error: nil)
    mon = bare_monitor(StubClient.new(jobs: jobs, error: error))
    issue = FakeIssue.new
    [mon.recheck_infra_recovery(issue), issue]
  end

  def test_an_unreachable_jobs_endpoint_does_not_rearm_the_row
    reentered, = recheck(error: api_error)

    refute reentered, 'an unread job list must not read as a recovered pipeline'
  end

  # Same rule as `check_stagnation_and_fix`: a cycle that never looked must not
  # spend one of the bounded attempts, or an outage burns the whole budget.
  def test_an_unreachable_jobs_endpoint_does_not_burn_a_recheck_attempt
    _reentered, issue = recheck(error: api_error)

    assert_equal 0, issue.infra_recheck_count
    assert_nil issue.infra_recheck_at
  end

  # Control: a red pipeline whose only failures are `allow_failure` really has
  # nothing blocking left, and that still re-arms the row.
  def test_a_genuinely_empty_failed_job_list_still_rearms_the_row
    reentered, = recheck(jobs: [{ 'name' => 'flaky', 'status' => 'failed', 'allow_failure' => true }])

    assert reentered
  end
end

# --- 3. a danger-claude evaluation that never ran is not a verdict ---------

# The fourth path of the Autodev #56 family, identified during its implementation
# and left out of scope then. `interpret_eval_result` returns nil both when the
# evaluation says "not code-related" (a verdict — waiting is the answer, and the
# age bound may count the poll) and when the evaluation could not be performed at
# all (no verdict — the bound must stand down).
class FailedEvaluationIsInconclusiveTest < Minitest::Test
  include ApiFailureFixtures

  class FakeIssue
    ABANDONABLE = %w[checking_pipeline fixing_discussions].freeze

    attr_reader :issue_iid, :mr_iid, :mr_url, :review_count, :issue_author_id,
                :checking_pipeline_since, :pipeline_poll_since, :pipeline_retrigger_count,
                :stagnation_signatures, :branch_name, :id

    def initialize
      @attrs = { status: 'checking_pipeline' }
      @issue_iid = 15_894
      @mr_iid = 42
      @mr_url = 'http://gitlab/mr/42'
      @issue_author_id = 7
      @review_count = 1
      @pipeline_retrigger_count = 1 # already retriggered: never re-enter that branch
      @branch_name = 'autodev/15894'
      @checking_pipeline_since = 20.days.ago
    end

    # rubocop:disable Naming/PredicateMethod -- mirrors AASM's bang event.
    def abandon!
      return false unless ABANDONABLE.include?(status)

      @attrs[:status] = 'done'
      @checking_pipeline_since = nil
      true
    end
    # rubocop:enable Naming/PredicateMethod

    def update(hash)
      @attrs.merge!(hash)
      @stagnation_signatures = hash[:stagnation_signatures] if hash.key?(:stagnation_signatures)
      @pipeline_poll_since = hash[:pipeline_poll_since] if hash.key?(:pipeline_poll_since)
      @checking_pipeline_since = hash[:checking_pipeline_since] if hash.key?(:checking_pipeline_since)
      self
    end

    def status = @attrs[:status]
    def needs_attention = @attrs[:needs_attention]
    def attention_reason = @attrs[:attention_reason]
  end

  class StubClient
    def initialize(jobs:) = @jobs = jobs

    def merge_request(_path,
                      _iid)
      ApiFailureFixtures::FakeMr.new('opened',
                                     ApiFailureFixtures::FakePipeline.new(9, 'failed'))
    end

    def pipeline_jobs(_path, _pid, **_opts) = @jobs
  end

  UNCERTAIN_JOBS = [{ 'name' => 'build', 'stage' => 'build', 'status' => 'failed',
                      'allow_failure' => false, 'failure_reason' => 'script_failure' }].freeze

  # A whole poll on a 20-day-old watch, red pipeline, pre-triage uncertain, so
  # the fix path reaches the Claude evaluation. `eval_result` is what
  # danger-claude gave back.
  def poll(eval_result:)
    sink = { notify: [], labels: [] }
    mon = bare_monitor(StubClient.new(jobs: UNCERTAIN_JOBS))
    stub_fix_path(mon, eval_result)
    stub_give_up_sinks(mon, sink)
    issue = FakeIssue.new
    mon.check(issue)
    [issue, sink]
  end

  # Everything between the failed-job list and the evaluation is stubbed: the
  # clone, the log files and danger-claude itself. What is exercised is how the
  # evaluation's answer travels back to the age bound.
  def stub_fix_path(mon, eval_result)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:log_activity) { |*, **| nil }
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :uncertain, explanation: nil } }
    mon.define_singleton_method(:prepare_work_dir) { |*| nil }
    mon.define_singleton_method(:write_and_categorize_jobs) { |*| [] }
    mon.define_singleton_method(:evaluate_code_related) { |*| eval_result }
    mon.define_singleton_method(:dispatch_fix) { |*| nil }
  end

  def stub_give_up_sinks(mon, sink)
    mon.define_singleton_method(:apply_label_done) { |iid| sink[:labels] << iid }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:reassign_to_author) { |*| nil }
  end

  def test_a_crashed_evaluation_does_not_expire_the_watch
    issue, sink = poll(eval_result: nil)

    assert_equal 'checking_pipeline', issue.status,
                 'a poll whose evaluation never ran concluded nothing and must not give the ticket up'
    assert_empty sink[:notify] + sink[:labels], 'nothing may be announced about a give-up that did not happen'
  end

  # Control, and the distinction that matters: "the failure is not code-related"
  # IS a verdict. The poll read one, decided to wait, and a fortnight of that is
  # exactly what Autodev #53's bound exists to stop.
  def test_a_non_code_verdict_still_expires_the_watch
    issue, sink = poll(eval_result: { 'code_related' => false, 'explanation' => 'runner died' })

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
    refute_empty sink[:notify]
  end
end

# --- 4. the second copy: MrFixer -----------------------------------------

# MrFixer's `fetch_unresolved_discussions` had the same `rescue → []`. It does
# not deliver — it sends the row back to `checking_pipeline` — but it announces
# "no unresolved discussions", resets the retrigger counter and burns a round on
# an MR it never read.
class MrFixerApiFailureTest < Minitest::Test
  include ApiFailureFixtures

  class FakeIssue
    attr_reader :issue_iid, :mr_iid, :fix_round, :attrs

    def initialize
      @issue_iid = 11_859
      @mr_iid = 42
      @fix_round = 0
      @attrs = { status: 'fixing_discussions' }
    end

    def update(hash) = (@attrs.merge!(hash) and self)
    def discussions_fixed! = @attrs[:status] = 'checking_pipeline'
    def status = @attrs[:status]
  end

  class StubClient
    def initialize(threads: [], error: nil)
      @threads = threads
      @error = error
    end

    def merge_request_discussions(_path, _iid, **_opts)
      raise @error if @error

      ApiFailureFixtures::FakePaginated.new(@threads)
    end
  end

  def run_fix(threads: [], error: nil)
    activity = []
    fixer = bare_fixer(StubClient.new(threads: threads, error: error), activity)
    issue = FakeIssue.new
    fixer.fix(issue)
    [issue, activity]
  end

  def bare_fixer(client, activity)
    MrFixer.allocate.tap do |fixer|
      fixer.instance_variable_set(:@client, client)
      fixer.instance_variable_set(:@project_path, 'group/project')
      fixer.instance_variable_set(:@logger, StubLogger.new)
      %i[log log_error].each { |noop| fixer.define_singleton_method(noop) { |*| nil } }
      fixer.define_singleton_method(:log_activity) { |_issue, key, **vars| activity << [key, vars] }
      fixer.define_singleton_method(:execute_fix_cycle) { |*| nil }
    end
  end

  def test_an_unreachable_discussions_endpoint_does_not_end_the_round
    issue, activity = run_fix(error: api_error)

    assert_equal 'fixing_discussions', issue.status, 'the row must wait for the next cycle'
    refute_includes activity.map(&:first), :discussions_none
  end

  def test_an_unreachable_discussions_endpoint_leaves_no_round_trace
    _issue, activity = run_fix(error: api_error)

    assert_empty activity, 'a round that could not read the MR must leave the note as it was'
  end

  # Control: a genuinely clean MR still goes back to the pipeline watch.
  def test_a_genuinely_clean_mr_still_ends_the_round
    issue, activity = run_fix(threads: [resolved_thread])

    assert_equal 'checking_pipeline', issue.status
    assert_includes activity.map(&:first), :discussions_none
  end

  def test_an_unresolved_thread_still_reaches_the_fix_cycle
    issue, activity = run_fix(threads: [unresolved_thread])

    assert_equal 'fixing_discussions', issue.status
    assert_includes activity.map(&:first), :discussions_found
  end
end

# --- 5. the shape itself -------------------------------------------------

# The ticket's own criterion: the next GitLab call added must not be able to
# reproduce the defect unnoticed. Two things carry that, and both are pinned
# here rather than left to the next reviewer's memory.
class DegradedApiValueShapeTest < Minitest::Test
  # (a) There is ONE definition of "the unresolved threads of an MR". There were
  # two, identical bar the return shape, and only one of them was on the
  # delivery path — so fixing that one would have left the other free to grow
  # the bug back at the next copy-paste.
  def test_both_callers_share_one_definition_of_the_unresolved_threads
    assert_equal MrDiscussions, MrFixer.instance_method(:fetch_unresolved_discussions).owner
    assert_equal MrDiscussions, PipelineMonitor.instance_method(:fetch_unresolved_discussions).owner
  end

  # (b) In the pipeline-monitor / MR-fixer tree, every place a GitLab error stops
  # travelling is declared below with the reason its substitute cannot be mistaken
  # for an answer. Everywhere else the error must reach a boundary — which is what
  # `GitlabHelpers.answer` guarantees for a wrapped read, and what a bare
  # `@client.…` call with no rescue at all already does for free.
  #
  # That is the whole of the ticket's criterion. The failure mode of Autodev #62 was
  # not that somebody wrote a bad rescue; it was that the rescue looked exactly like
  # every other line around it, in four places, and nothing made a reviewer ask what
  # the substitute would be read as. Adding one now means editing this list, in the
  # same commit, with a sentence.
  ALLOWED_SWALLOWS = {
    'lib/autodev/pipeline_monitor.rb' => {
      # The boundary of one poll: the whole point is that the failure stops here,
      # with the row untouched and `abandon_expired_watch` unreached.
      'check' => 'poll boundary'
    },
    'lib/autodev/mr_fixer.rb' => {
      # The boundary of one fix round, for the same reason — and so the exception
      # does not reach ActiveJob and park the row in Solid Queue's failed
      # executions, which needs a human for something the next cycle retries.
      'fix' => 'fix-round boundary',
      # A write. Failing to mark a thread resolved leaves it unresolved, which the
      # next round re-reads. No verdict is inferred from the failure.
      'resolve_discussion' => 'write, not a read'
    },
    'lib/autodev/mr_fixer/fix_cycle.rb' => {
      # Clone, rebase, danger-claude, push. `fetch_unresolved_discussions` is
      # performed by `MrFixer#fix` *before* calling in here, on purpose, and the
      # prompt-context read inside `prepare_fix_environment` now raises
      # `ApiUnavailableError`, which this method re-raises above its two handlers
      # (Autodev #67 — it used to be swallowed here and imputed to the fix).
      #
      # Audited, not assumed: the only GitLab traffic left under this method is
      # `resolve_discussion` (a write, declared below), `ScreenshotUploader.process`
      # (uploads, own rescues) and `log_activity` / `notify_localized`, which
      # swallow their own failures because a note that could not be edited is not
      # a verdict either.
      'execute_fix_cycle' => 'fix-round boundary: clone, rebase, danger-claude, push'
    },
    'lib/autodev/mr_fixer/discussion_formatter.rb' => {
      # `git diff` in a work directory, for the prompt. No GitLab call, and the
      # substitute (`nil` = no diff hunk to quote) removes context from a prompt
      # rather than answering a question.
      'extract_diff_hunk' => 'local git, not a read'
    },
    'lib/autodev/pipeline_monitor/infra_recheck.rb' => {
      # The boundary of one recheck. `false` means "do not re-enter", which is the
      # conservative answer and the one the caller wants when nothing was read.
      'recheck_infra_recovery' => 'recheck boundary'
    },
    'lib/autodev/pipeline_monitor/failure_handler.rb' => {
      # A write. `false` means "the pipeline was not retriggered", which is exactly
      # what happened; the caller falls through to the triage it would have run.
      'retrigger_if_needed' => 'write, not a read',
      # Everything from the triage onwards: clone, danger-claude, push. `handle_red`
      # reads the failed jobs *before* calling in here — that hoist is Autodev #62's.
      #
      # The prompt-context read underneath (`build_fix_context_hash` →
      # `GitlabHelpers.fetch_full_context`) was the gap #62 left and Autodev #67
      # closed. It could not be hoisted out of here the way the job list was — it
      # needs the clone's work directory, for the ticket's images — so instead it
      # raises `ApiUnavailableError` and this method re-raises it above its two
      # handlers, and `dispatch_fix` performs it *before* `pipeline_failed_code!` so
      # the abort leaves the row in `checking_pipeline`.
      #
      # Audited, not assumed: the GitLab traffic left under this method is
      # `retry_pipeline` and `fetch_job_trace` (both declared here) plus the label /
      # assignee / note writes of `abandon_issue`, `log_activity` and
      # `notify_localized`, each of which swallows its own failure.
      'attempt_fix' => 'fix boundary: clone, danger-claude, push'
    },
    'lib/autodev/pipeline_monitor/reviewer.rb' => {
      # mr-review is a subprocess, not a GitLab call. A crash is already non-fatal
      # by design (`false` = review not performed, the round is not counted), and
      # Autodev #49 made the diagnostic survive it.
      'execute_mr_review' => 'subprocess, not a read'
    },
    'lib/autodev/pipeline_monitor/api_helpers.rb' => {
      # The one read still allowed to substitute. The substitute names itself in the
      # value ("(trace unavailable: …)"), it is written into a log file for a human
      # or for Claude to read as prose rather than compared against anything, and one
      # unreadable trace must not abandon the fix of the jobs whose traces arrived.
      'fetch_job_trace' => 'self-describing prose, not a verdict'
    }
  }.freeze

  SCANNED = %w[
    lib/autodev/pipeline_monitor.rb lib/autodev/mr_fixer.rb lib/autodev/mr_discussions.rb
  ].freeze

  SCANNED_DIRS = %w[lib/autodev/pipeline_monitor lib/autodev/mr_fixer].freeze

  def test_every_swallowed_gitlab_error_in_the_delivery_path_is_declared
    undeclared = scanned_files.flat_map { |rel, abs| undeclared_swallows(rel, abs) }

    assert_empty undeclared, <<~MSG
      A GitLab error is caught and not re-raised here: #{undeclared.join(', ')}.

      Whatever the method returns instead, some caller will read it as an answer —
      that is Autodev #62. Either let it raise (GitlabHelpers.answer is the
      conversion point) or add the method to ALLOWED_SWALLOWS with the reason its
      substitute cannot be mistaken for a verdict.
    MSG
  end

  # Line-by-line walk of one file, collecting the names of the methods whose
  # `rescue` of a GitLab error does not re-raise. Deliberately textual: what it
  # checks is a property of the source a reader sees, and the point is to make the
  # list above the only place the exceptions live.
  class SwallowScanner
    # A clause counts when it *can catch* a failed read, not when it happens to
    # name one. `ApiUnavailableError < AutodevError < StandardError`, so a
    # `rescue StandardError` swallows it just as thoroughly as a clause naming it
    # — and it is the more likely way to reintroduce Autodev #62, because it does
    # not look like it has anything to do with GitLab. A bare `rescue` and
    # `rescue => e` are StandardError spelled shorter. Clauses that name an
    # unrelated class (`RateLimitError`, `JSON::ParserError`) cannot catch a
    # failed read and are ignored.
    NAMED = /^\s*rescue\s+.*(Gitlab::Error|ApiUnavailableError|AutodevError|StandardError)/
    CATCH_ALL = /^\s*rescue\s*(=>|$|#)/
    CLAUSE_END = /^\s*(end|def|rescue|ensure)\b/
    # Read on the code, never on a comment: a rescue body whose comment merely
    # contains the word "raise" swallows exactly as much as one that does not.
    RERAISE = /\braise\b/
    COMMENT = /#.*/
    METHOD_DEF = /^\s*def\s+([a-z_][\w?!]*)/

    def initialize(lines)
      @lines = lines
      @found = []
      @clause = nil
      @method = nil
    end

    def swallowing_methods
      @lines.each { |line| step(line) }
      close_clause
      @found
    end

    private

    def step(line)
      close_clause if @clause && line.match?(CLAUSE_END)
      if catches_failed_read?(line)
        @clause = { method: @method, reraises: false }
        return
      end
      @method = ::Regexp.last_match(1) if line =~ METHOD_DEF
      @clause[:reraises] = true if @clause && line.sub(COMMENT, '').match?(RERAISE)
    end

    def catches_failed_read?(line)
      line.match?(NAMED) || line.match?(CATCH_ALL)
    end

    def close_clause
      return unless @clause

      @found << @clause[:method] unless @clause[:reraises]
      @clause = nil
    end
  end

  private

  def undeclared_swallows(rel, abs)
    SwallowScanner.new(File.readlines(abs)).swallowing_methods
                  .reject { |method| ALLOWED_SWALLOWS.fetch(rel, {}).key?(method) }
                  .map { |method| "#{rel}##{method}" }
  end

  def scanned_files
    root = File.expand_path('..', __dir__)
    rels = SCANNED + SCANNED_DIRS.flat_map do |dir|
      Dir[File.join(root, dir, '*.rb')].map { |abs| abs.delete_prefix("#{root}/") }
    end
    rels.map { |rel| [rel, File.join(root, rel)] }
  end
end
