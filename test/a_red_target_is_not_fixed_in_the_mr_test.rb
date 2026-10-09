# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'active_support/testing/time_helpers'

# Autodev #130 — a job already red on the target branch is not "fixed" in the
# merge request.
#
# Measured on production before the change: of 304 pipeline-fix rounds whose
# merge request pipeline could be read, 6 handed `PipelineFixer` a job whose
# failure was the target's own — same job, same failure signature, on the last
# finished pipeline of the branch the merge request goes into — and in 3 of them
# every red job was. powerpanne 16735 was given up under `stagnation_pipeline`
# on 16/09/2026 while `master` was red on the very same `bundle install` error.
#
# What these tests hold, driven through `PipelineMonitor#check`:
#
#   * a pre-existing job reaches neither the fixer nor the stagnation signature,
#     and the activity note and one merge request comment name it and the target
#     pipeline;
#   * a job the target does not explain — green there, or red for another
#     reason — is fixed exactly as before;
#   * when every red job is pre-existing the row holds, retries the merge request
#     pipeline once the target recovers, and gives up at the age bound under its
#     own reason, `target_pipeline_red`, never `pipeline_watch_expired`.
module RedTargetFixtures
  THRESHOLD = 3
  MR_PIPELINE = 5001
  TARGET_PIPELINE = 9001
  TARGET_URL = 'https://gitlab.example/group/project/-/pipelines/9001'

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review',
                     'label_attention' => 'Development::StandBy',
                     'stagnation_threshold' => THRESHOLD }.freeze

  def self.job(id, name, status: 'failed', allow_failure: false)
    { 'id' => id, 'name' => name, 'stage' => 'test', 'status' => status,
      'allow_failure' => allow_failure, 'failure_reason' => 'script_failure' }
  end

  def self.trace(*lines)
    (["section_start:1:step_script\r"] + lines + ["section_end:2:step_script\r", 'ERROR: Job failed']).join("\n")
  end

  SPEC_FAILURE = trace('Failed examples:', 'rspec ./spec/a_spec.rb:12 # breaks')
  OTHER_SPEC_FAILURE = trace('Failed examples:', 'rspec ./spec/z_spec.rb:1 # mine')
  GIT_FAILURE = trace('$ bundle install', 'fatal: hardlink different from source at')

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Everything the poll reads. The merge request pipeline's jobs and the target's
  # are separate lists, each job's trace is looked up by its id.
  class FakeClient
    GlIssue = Struct.new(:iid, :title, :description, :labels, :id)
    GlNote = Struct.new(:id, :body, :system, :author, :created_at)
    GlMr = Struct.new(:state, :head_pipeline, :target_branch)
    GlPipeline = Struct.new(:id, :status, :web_url)

    class Paginated
      def initialize(items) = @items = items
      def auto_paginate = @items
    end

    attr_accessor :mr_jobs, :target_pipelines, :target_jobs, :traces, :target_branch, :pipelines_down, :head
    # `failures[:retry]`, `failures[:mr_note]`, `failures[:target_jobs]`,
    # `failures[[:trace, jid]]`: the exception the next such call raises, once.
    attr_reader :failures
    attr_reader :notes, :mr_notes, :retries, :pipelines_reads, :trace_reads

    def initialize
      @target_pipelines = [GlPipeline.new(id: TARGET_PIPELINE, status: 'failed', web_url: TARGET_URL)]
      @target_jobs = { TARGET_PIPELINE => [] }
      @target_branch = 'master'
      @head = GlPipeline.new(id: MR_PIPELINE, status: 'failed')
      @mr_jobs, @notes, @mr_notes, @retries = Array.new(4) { [] }
      @traces = {}
      @failures = {}
      @pipelines_reads = @trace_reads = 0
    end

    def self.response_error(code)
      Gitlab::Error::ResponseError.new(
        FakeResponse.new('boom', code, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
      )
    end

    def merge_request(_path, _iid)
      GlMr.new(state: 'opened', head_pipeline: @head, target_branch: @target_branch)
    end

    def pipelines(_path, **opts)
      @pipelines_reads += 1
      raise api_error if @pipelines_down
      raise "unexpected ref #{opts[:ref]}" unless opts[:ref] == @target_branch

      @target_pipelines.first(opts.fetch(:per_page, 20))
    end

    # Any pipeline that is not one of the target's is the merge request's.
    def pipeline_jobs(_path, pid, **_opts)
      return @mr_jobs unless @target_jobs.key?(pid)

      fail_once(:target_jobs)
      @target_jobs[pid]
    end

    def job_trace(_path, jid)
      @trace_reads += 1
      fail_once([:trace, jid])
      @traces.fetch(jid, '')
    end

    def retry_pipeline(_path, pid)
      fail_once(:retry)
      @retries << pid
      nil
    end

    def create_merge_request_note(_path, _iid, body)
      fail_once(:mr_note)
      @mr_notes << body
      GlNote.new(id: @mr_notes.size, body: body, system: false)
    end

    def issue(_path, iid) = GlIssue.new(iid: iid, title: 'Ticket', description: 'the body', labels: [], id: 1)
    def issue_notes(_path, _iid, **_opts) = Paginated.new([])
    def issue_links(_path, _iid) = []
    def merge_request_discussions(_path, _iid, **_opts) = Paginated.new([])
    def user = GlIssue.new(id: 999, labels: [])
    def edit_issue(_path, iid, **_attrs) = GlIssue.new(iid: iid, labels: [], id: 1)

    def create_issue_note(_path, _iid, body)
      @notes << body
      GlNote.new(id: @notes.size, body: body, system: false)
    end

    def issue_note(_path, _iid, note_id) = GlNote.new(id: note_id, body: @notes.last.to_s)

    def edit_issue_note(_path, _iid, _note_id, body)
      @notes[-1] = body
      GlNote.new(id: 1, body: body, system: false)
    end

    private

    def fail_once(key)
      error = @failures.delete(key)
      raise error if error
    end

    def api_error
      Gitlab::Error::ResponseError.new(
        FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/pipelines'))
      )
    end
  end

  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  # The fix itself is stubbed at the clone: what reaches it is recorded, which is
  # the "was PipelineFixer launched on this job" question. Claude's gate is
  # counted, so a poll that asked for it is visible.
  def monitor(client, project_config: PROJECT_CONFIG)
    calls = { fixed: [], claude_gate: 0 }
    mon = PipelineMonitor.allocate
    mon.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                           project_config: project_config, logger: NullLogger.new, token: 'tok')
    mon.define_singleton_method(:claude_available?) { (calls[:claude_gate] += 1).positive? }
    mon.define_singleton_method(:clone_and_fix) do |_issue, failed_jobs, _triage|
      calls[:fixed] << failed_jobs.map { |j| GitlabHelpers.field(j, :name) }
    end
    [mon, calls]
  end

  # `since:` back-dates the watch clock, which entering `checking_pipeline` stamps.
  def watched_issue(since: nil, **attrs)
    issue = create_issue(mr_iid: 7, mr_url: 'http://gitlab/mr/7', issue_author_id: 42,
                         branch_name: 'autodev/130', locale: 'fr', **attrs)
    advance_to(issue, 'checking_pipeline')
    issue.update(checking_pipeline_since: since) if since
    issue
  end

  # A hold on the merge request pipeline that began at `at`: the hold's own clock
  # (owner's decision of 09/10/2026), not the watch's.
  def hold_begun(at)
    { target_red_hold_pipeline_id: MR_PIPELINE, target_red_hold_since: at }
  end

  def held_since(at, **attrs)
    watched_issue(**hold_begun(at), **attrs)
  end

  # The merge request's `test` failed on spec a_spec.rb:12, and so did `master`'s.
  def preexisting_test_job(client)
    client.mr_jobs = [RedTargetFixtures.job(1, 'test')]
    client.target_jobs = { TARGET_PIPELINE => [RedTargetFixtures.job(101, 'test')] }
    client.traces = { 1 => SPEC_FAILURE, 101 => SPEC_FAILURE }
  end

  def stagnation(issue)
    JSON.parse(issue.reload.stagnation_signatures || '{}')['pipeline']
  end

  # Whether one of `notes` carries every word.
  def naming?(notes, *words)
    notes.any? { |note| words.all? { |word| note.include?(word.to_s) } }
  end

  # The target's latest finished pipeline is now green on `test`.
  def recover_target(client)
    client.target_pipelines = [FakeClient::GlPipeline.new(id: 9003, status: 'success', web_url: 'u3')]
    client.target_jobs[9003] = [RedTargetFixtures.job(103, 'test', status: 'success')]
  end

  # A new latest finished pipeline on the target, red on `test` for `trace`.
  def new_target_pipeline(client, id, trace)
    client.target_pipelines = [FakeClient::GlPipeline.new(id: id, status: 'failed', web_url: "u#{id}")]
    client.target_jobs[id] = [RedTargetFixtures.job(id + 1000, 'test')]
    client.traces[id + 1000] = trace
  end

  # `test` red here and on the target for the same reason, `rubocop` red here only.
  def two_red_jobs(client)
    preexisting_test_job(client)
    client.mr_jobs << RedTargetFixtures.job(2, 'rubocop')
    client.traces[2] = OTHER_SPEC_FAILURE
  end
end

class PreexistingFailureIsNotFixedTest < Minitest::Test
  include DatabaseTestHelper
  include RedTargetFixtures

  def setup = setup_database

  def test_a_job_red_on_the_target_for_the_same_reason_is_not_fixed
    client = FakeClient.new
    preexisting_test_job(client)
    mon, calls = monitor(client)
    issue = watched_issue

    mon.check(issue)

    assert_equal({ fixed: [], claude_gate: 0 }, calls,
                 'PipelineFixer, or Claude\'s gate, was reached on a failure that is the target branch\'s')
    assert_nil stagnation(issue), 'a pre-existing failure counted towards pipeline stagnation'
    assert_equal ['checking_pipeline', MR_PIPELINE], [issue.reload.status, issue.target_red_hold_pipeline_id]
  end

  def test_it_says_so_on_the_merge_request_naming_the_job_and_the_target_pipeline
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)

    mon.check(watched_issue)

    assert_equal [1, true], [client.mr_notes.size, naming?(client.mr_notes, 'test', 'master', TARGET_URL)],
                 "expected one comment naming the job, the target and its pipeline: #{client.mr_notes}"
  end

  def test_the_activity_note_names_the_job_and_the_target_pipeline
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)

    mon.check(watched_issue)

    assert naming?(client.notes, 'test', 'master', TARGET_PIPELINE), "not in the activity note: #{client.notes}"
  end

  def test_a_hold_comments_once_however_many_polls_it_lasts
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)
    issue = watched_issue

    3.times { mon.check(issue.reload) }

    assert_equal 1, client.mr_notes.size
  end

  # Two traces of up to 4 MiB each, every poll interval, for as long as a hold
  # lasts: the answer on the same two pipelines is the same, and is not re-read.
  def test_a_hold_does_not_read_the_traces_again_on_the_same_pipelines
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)
    issue = watched_issue
    mon.check(issue)
    first_poll = client.trace_reads

    2.times { mon.check(issue.reload) }

    assert_equal [2, 2], [first_poll, client.trace_reads]
  end

  # A new pipeline on the target is a new comparison: the target may now be red
  # for another reason.
  def test_a_new_target_pipeline_is_compared_again
    client = FakeClient.new
    preexisting_test_job(client)
    mon, calls = monitor(client)
    issue = watched_issue
    mon.check(issue)
    new_target_pipeline(client, 9004, GIT_FAILURE)

    mon.check(issue.reload)

    assert_equal [[MR_PIPELINE], []], [client.retries, calls[:fixed]],
                 'the target no longer explains the job: the held pipeline is retried'
  end

  def test_a_hold_never_counts_towards_stagnation
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)
    issue = watched_issue

    (THRESHOLD + 2).times { mon.check(issue.reload) }

    assert_equal [false, 'checking_pipeline'], [issue.reload.needs_attention, issue.status]
    assert_nil stagnation(issue)
  end
end

class OwnFailureIsStillFixedTest < Minitest::Test
  include DatabaseTestHelper
  include RedTargetFixtures

  def setup = setup_database

  # 16/09/2026: `master` failed `test:main` in `bundle install`; the merge
  # requests failing `test:main` on their specs at that moment were not the
  # target's failure.
  def test_the_same_job_red_on_the_target_for_another_reason_is_fixed
    client = FakeClient.new
    preexisting_test_job(client)
    client.traces[101] = GIT_FAILURE
    mon, calls = monitor(client)
    issue = watched_issue

    mon.check(issue)

    assert_equal [[['test']], 1], [calls[:fixed], stagnation(issue)['count']]
    assert_equal [[], nil], [client.mr_notes, issue.reload.target_red_hold_pipeline_id]
  end

  def test_a_job_green_on_the_target_is_fixed
    client = FakeClient.new
    client.mr_jobs = [RedTargetFixtures.job(1, 'test')]
    client.target_jobs = { TARGET_PIPELINE => [RedTargetFixtures.job(101, 'test', status: 'success')] }
    client.traces = { 1 => SPEC_FAILURE }
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
    assert_empty client.mr_notes
  end

  def test_a_job_the_target_lets_fail_is_not_pre_existing
    client = FakeClient.new
    client.mr_jobs = [RedTargetFixtures.job(1, 'test')]
    client.target_jobs = { TARGET_PIPELINE => [RedTargetFixtures.job(101, 'test', allow_failure: true)] }
    client.traces = { 1 => SPEC_FAILURE, 101 => SPEC_FAILURE }
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
  end

  def test_a_truncated_trace_is_never_pre_existing
    client = FakeClient.new
    preexisting_test_job(client)
    client.traces[1] = "#{SPEC_FAILURE}\nJob's log exceeded limit of 4194304 bytes."
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
  end

  # One more failing example than the target: the merge request broke it.
  def test_an_extra_failing_example_is_the_merge_requests_own
    client = FakeClient.new
    preexisting_test_job(client)
    client.traces[1] = RedTargetFixtures.trace('rspec ./spec/a_spec.rb:12 # x', 'rspec ./spec/z_spec.rb:1 # y')
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
  end

  def test_with_two_red_jobs_only_the_merge_requests_own_reaches_the_fixer_and_the_signature
    client = FakeClient.new
    two_red_jobs(client)
    mon, calls = monitor(client)
    issue = watched_issue

    mon.check(issue)

    assert_equal [[['rubocop']], Digest::SHA256.hexdigest('rubocop')], [calls[:fixed], stagnation(issue)['signature']],
                 'the pre-existing job reached the fixer or the stagnation signature'
    assert_nil issue.reload.target_red_hold_pipeline_id, 'a round that fixes something is not a hold'
  end

  def test_with_two_red_jobs_the_comment_names_only_the_pre_existing_one
    client = FakeClient.new
    two_red_jobs(client)
    mon, = monitor(client)

    mon.check(watched_issue)

    assert_equal [true, false], [naming?(client.mr_notes, 'test'), naming?(client.mr_notes, 'rubocop')]
  end

  # A merge request naming no target has nothing to be compared to; the rebase
  # further down is what reports it (`MissingTargetBranchError`).
  def test_a_merge_request_with_no_target_is_handled_as_before
    client = FakeClient.new
    preexisting_test_job(client)
    client.target_branch = nil
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
    assert_equal 0, client.pipelines_reads
  end
end

class TargetPipelineChoiceTest < Minitest::Test
  include DatabaseTestHelper
  include RedTargetFixtures

  def setup = setup_database

  # The newest pipeline is still running: its jobs have no verdict. The latest
  # *finished* one decides, and `manual` is how `master` finishes on powerpanne.
  def test_a_running_target_pipeline_is_skipped_and_manual_counts_as_finished
    client = FakeClient.new
    preexisting_test_job(client)
    client.target_pipelines = [FakeClient::GlPipeline.new(id: 9002, status: 'running', web_url: 'u2'),
                               FakeClient::GlPipeline.new(id: TARGET_PIPELINE, status: 'manual', web_url: TARGET_URL)]
    client.target_jobs[9002] = [RedTargetFixtures.job(102, 'test', status: 'success')]
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_empty calls[:fixed]
  end

  def test_no_finished_target_pipeline_means_own
    client = FakeClient.new
    preexisting_test_job(client)
    client.target_pipelines = [FakeClient::GlPipeline.new(id: TARGET_PIPELINE, status: 'running', web_url: 'u')]
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
  end

  # An unreadable target is not a green target (Autodev #62): the poll concludes
  # nothing and the row is left exactly as it was.
  def test_an_unreadable_target_aborts_the_poll
    client = FakeClient.new
    preexisting_test_job(client)
    client.pipelines_down = true
    mon, calls = monitor(client)
    issue = watched_issue

    mon.check(issue)

    assert_empty calls[:fixed]
    assert_equal ['checking_pipeline', nil], [issue.reload.status, stagnation(issue)]
    assert_empty client.mr_notes
  end
end

class HeldPipelineTest < Minitest::Test
  include DatabaseTestHelper
  include RedTargetFixtures

  def setup = setup_database

  def test_the_merge_request_pipeline_is_retried_once_the_target_recovers
    client = FakeClient.new
    preexisting_test_job(client)
    mon, calls = monitor(client)
    issue = watched_issue
    mon.check(issue)
    recover_target(client)

    mon.check(issue.reload)

    assert_equal [[MR_PIPELINE], [], nil, nil],
                 [client.retries, calls[:fixed], issue.reload.target_red_hold_pipeline_id, issue.target_red_hold_key],
                 'expected one retry, no fix on that poll, and the hold released'
  end

  def test_the_retry_is_in_the_activity_note
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)
    issue = watched_issue
    mon.check(issue)
    recover_target(client)

    mon.check(issue.reload)

    assert naming?(client.notes, 'master ne montre plus le meme echec'),
           "no activity line for the retry: #{client.notes}"
  end

  # Integration review of the alpha-57 lot: the target untouched (same
  # pipeline, same red job, same trace), a human retries the merge request's
  # `test` alone and it now fails on another example. The retry is right; the
  # line used to say the target "no longer shows the same failure", which is
  # false — it is the merge request's job that moved.
  def test_a_retry_after_only_the_merge_requests_job_changed_says_so
    client = FakeClient.new
    hold_then_retry_the_merge_requests_job(client)

    assert_equal [[MR_PIPELINE], true, false],
                 [client.retries, naming?(client.notes, 'La branche master est inchangee', TARGET_PIPELINE, 'test'),
                  naming?(client.notes, 'ne montre plus le meme echec')],
                 "expected the retry, said of the merge request's job, not of the target: #{client.notes}"
  end

  # Held on `test`, then the merge request's `test` alone retried: a new job
  # id, now failing on another example, the target untouched.
  def hold_then_retry_the_merge_requests_job(client)
    preexisting_test_job(client)
    mon, = monitor(client)
    issue = watched_issue
    mon.check(issue)
    client.mr_jobs = [RedTargetFixtures.job(3, 'test')]
    client.traces[3] = OTHER_SPEC_FAILURE
    mon.check(issue.reload)
  end

  # Released by the retry, the next failure on that pipeline is no longer the
  # target's: it is fixed as today.
  def test_after_the_retry_a_failure_the_target_does_not_explain_is_fixed
    client = FakeClient.new
    preexisting_test_job(client)
    mon, calls = monitor(client)
    issue = watched_issue
    mon.check(issue)
    recover_target(client)
    mon.check(issue.reload)

    mon.check(issue.reload)

    assert_equal [MR_PIPELINE], client.retries
    assert_equal [['test']], calls[:fixed]
  end

  def test_a_hold_past_the_age_bound_ends_under_its_own_reason
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)
    issue = held_since(15.days.ago)

    mon.check(issue)

    assert_equal %w[done target_pipeline_red], [issue.reload.status, issue.attention_reason]
    # The pipeline's URL is only in the give-up comment: the activity journal
    # names it by its number.
    assert naming?(client.notes, 'test', 'master', TARGET_URL),
           "the give-up does not name the job, the target and its pipeline: #{client.notes.inspect}"
  end

  # The watch card's "Job(s) en cause" reads the detail.
  def test_the_give_up_records_the_jobs_as_its_detail
    client = FakeClient.new
    preexisting_test_job(client)
    mon, = monitor(client)
    issue = held_since(15.days.ago)

    mon.check(issue)

    assert_equal 'test', issue.reload.attention_detail
  end

  # The hold column outlives the poll that wrote it. A watch that expires on a
  # poll that did not hold — here the merge request pipeline is running — is the
  # ordinary expiry.
  def test_an_expiry_on_a_poll_that_did_not_hold_is_the_ordinary_one
    client = FakeClient.new
    issue = watched_issue(since: 15.days.ago, target_red_hold_pipeline_id: MR_PIPELINE)
    client.define_singleton_method(:merge_request) do |_p, _i|
      FakeClient::GlMr.new(state: 'opened', head_pipeline: FakeClient::GlPipeline.new(id: 5002, status: 'running'),
                           target_branch: 'master')
    end
    mon, = monitor(client)

    mon.check(issue)

    assert_equal %w[done pipeline_watch_expired], [issue.reload.status, issue.attention_reason]
  end
end

# The decisions the plan review found the tests above would not notice if they
# were implemented wrong — one test each.
module PreexistingEdgeHelpers
  include RedTargetFixtures

  def preexisting_client
    FakeClient.new.tap { |client| preexisting_test_job(client) }
  end

  # A monitor that has already polled once, on a held pipeline.
  def held(client, **issue_attrs)
    mon, calls = monitor(client)
    issue = watched_issue(**issue_attrs)
    mon.check(issue)
    [mon, calls, issue.reload]
  end

  # A second red job, `lint`, red on the target for the same reason.
  def add_held_lint_job(client)
    client.mr_jobs << RedTargetFixtures.job(2, 'lint')
    client.target_jobs[TARGET_PIPELINE] << RedTargetFixtures.job(102, 'lint')
    client.traces.merge!(2 => GIT_FAILURE, 102 => GIT_FAILURE)
  end

  # Two held jobs, `test` and `lint`; then a target pipeline where `lint` is green.
  def hold_two_then_recover_one(client)
    add_held_lint_job(client)
    result = held(client)
    client.target_pipelines = [FakeClient::GlPipeline.new(id: 9005, status: 'failed', web_url: 'u5')]
    client.target_jobs[9005] = [RedTargetFixtures.job(101, 'test'),
                                RedTargetFixtures.job(102, 'lint', status: 'success')]
    result
  end

  # A new target pipeline red on `test` and on `rubocop`, each for the reason
  # it fails for in the merge request.
  def target_explains_both(client)
    new_target_pipeline(client, 9006, SPEC_FAILURE)
    client.target_jobs[9006] << RedTargetFixtures.job(9007, 'rubocop')
    client.traces[9007] = OTHER_SPEC_FAILURE
  end

  def assert_untouched_abort(client)
    mon, calls = monitor(client)
    issue = watched_issue

    mon.check(issue)

    assert_equal [[], 'checking_pipeline', nil, [], nil],
                 [calls[:fixed], issue.reload.status, stagnation(issue), client.mr_notes,
                  issue.target_red_hold_pipeline_id]
  end
end

class PreexistingTargetChoiceEdgesTest < Minitest::Test
  include DatabaseTestHelper
  include PreexistingEdgeHelpers

  def setup = setup_database

  # The split sits after the pre-triage, the one retrigger and the infra wait:
  # an infra failure is retried, then waited on, and never compared.
  def test_an_infra_failure_never_reaches_the_comparison
    client = preexisting_client
    client.mr_jobs = [RedTargetFixtures.job(1, 'test').merge('failure_reason' => 'runner_system_failure')]
    mon, = monitor(client)
    issue = watched_issue

    2.times { mon.check(issue.reload) }

    assert_equal [[MR_PIPELINE], 0, 1], [client.retries, client.pipelines_reads, stagnation(issue)['count']]
  end

  # The newest finished pipeline decides, not any finished one.
  def test_an_older_red_target_pipeline_does_not_count_once_a_newer_one_is_green
    client = preexisting_client
    client.target_pipelines.unshift(FakeClient::GlPipeline.new(id: 9003, status: 'success', web_url: 'u3'))
    client.target_jobs[9003] = [RedTargetFixtures.job(103, 'test', status: 'success')]
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [[['test']], []], [calls[:fixed], client.mr_notes]
  end

  %w[canceled skipped].each do |status|
    define_method(:"test_a_#{status}_target_job_is_not_pre_existing") do
      client = preexisting_client
      client.target_jobs[TARGET_PIPELINE] = [RedTargetFixtures.job(101, 'test', status: status)]
      mon, calls = monitor(client)

      mon.check(watched_issue)

      assert_equal [['test']], calls[:fixed]
    end
  end

  # Two traces GitLab refused would share a placeholder and compare equal: a
  # refused trace is no signature, and the job is the merge request's.
  def test_refused_traces_are_not_pre_existing
    client = preexisting_client
    client.failures[[:trace, 1]] = FakeClient.response_error(404)
    client.failures[[:trace, 101]] = FakeClient.response_error(404)
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
  end

  def test_a_trace_request_that_never_completed_aborts_the_poll
    client = preexisting_client
    client.failures[[:trace, 101]] = Net::ReadTimeout.new

    assert_untouched_abort(client)
  end

  def test_an_unreadable_target_job_list_aborts_the_poll
    client = preexisting_client
    client.failures[:target_jobs] = FakeClient.response_error(500)

    assert_untouched_abort(client)
  end
end

class PreexistingHoldEdgesTest < Minitest::Test
  include DatabaseTestHelper
  include PreexistingEdgeHelpers

  def setup = setup_database

  # The "this poll held" flag is the poll's own: a later poll of the same
  # monitor that did not hold expires as the ordinary watch.
  def test_the_hold_flag_does_not_outlive_its_poll
    client = preexisting_client
    mon, _, issue = held(client, since: 10.days.ago)
    issue.update(checking_pipeline_since: 15.days.ago)
    client.head = FakeClient::GlPipeline.new(id: 5002, status: 'running')

    mon.check(issue)

    assert_equal %w[done pipeline_watch_expired], [issue.reload.status, issue.attention_reason]
  end

  # A hold recorded on another pipeline is not this one's: its own failure is
  # fixed, nothing is retried.
  def test_a_hold_on_another_pipeline_is_not_retried
    client = preexisting_client
    client.target_jobs[TARGET_PIPELINE] = [RedTargetFixtures.job(101, 'test', status: 'success')]
    mon, calls = monitor(client)

    mon.check(watched_issue(target_red_hold_pipeline_id: 5000))

    assert_equal [[], [['test']]], [client.retries, calls[:fixed]]
  end

  # Two held jobs, one recovered: waiting can no longer explain every red job.
  def test_one_recovered_job_of_two_is_enough_to_retry
    client = preexisting_client
    mon, calls, issue = hold_two_then_recover_one(client)

    mon.check(issue)

    assert_equal [[MR_PIPELINE], [], nil], [client.retries, calls[:fixed], issue.reload.target_red_hold_pipeline_id]
  end

  [Net::ReadTimeout.new, FakeClient.response_error(500)].each do |error|
    define_method(:"test_a_retry_refused_by_#{error.class.name.gsub('::', '_')}_keeps_the_hold") do
      client = preexisting_client
      mon, calls, issue = held(client)
      recover_target(client)
      client.failures[:retry] = error

      mon.check(issue)

      assert_equal ['checking_pipeline', MR_PIPELINE, [], []],
                   [issue.reload.status, issue.target_red_hold_pipeline_id, client.retries, calls[:fixed]]
      mon.check(issue.reload)

      assert_equal [MR_PIPELINE], client.retries, 'the next poll did not retry'
    end
  end
end

class PreexistingAnnouncementEdgesTest < Minitest::Test
  include DatabaseTestHelper
  include PreexistingEdgeHelpers

  def setup = setup_database

  # A new merge request pipeline with the same pre-existing job is a new round,
  # and gets its own comment.
  def test_a_new_merge_request_pipeline_comments_again
    client = preexisting_client
    mon, _, issue = held(client)
    client.head = FakeClient::GlPipeline.new(id: 5002, status: 'failed')

    mon.check(issue)

    assert_equal 2, client.mr_notes.size
  end

  def test_a_comment_that_failed_is_posted_by_the_next_poll
    client = preexisting_client
    client.failures[:mr_note] = Net::ReadTimeout.new
    mon, _, issue = held(client)

    assert_equal ['checking_pipeline', MR_PIPELINE, nil],
                 [issue.status, issue.target_red_hold_pipeline_id, issue.preexisting_noted_key]
    mon.check(issue)

    assert_equal 1, client.mr_notes.size
  end

  # Fourteen days of a hold must not grow the activity note by a line a poll.
  { 'fr' => /Deja en echec sur/, 'en' => /Already failing on/ }.each do |locale, line|
    define_method(:"test_the_activity_line_is_rewritten_in_place_#{locale}") do
      client = preexisting_client
      mon, = monitor(client)
      issue = watched_issue(locale: locale)

      3.times { mon.check(issue.reload) }

      assert_equal(1, client.notes.sum { |note| note.scan(line).size })
    end
  end
end

# The second round of gaps, found by mutating the code under the tests above.
class PreexistingSabotageGapsTest < Minitest::Test
  include DatabaseTestHelper
  include PreexistingEdgeHelpers

  def setup = setup_database

  # The comment is written in the request's language.
  def test_the_merge_request_comment_is_in_the_requests_language
    client = preexisting_client
    mon, = monitor(client)

    mon.check(watched_issue(locale: 'en'))

    assert naming?(client.mr_notes, 'already fails on `master`'), "not in English: #{client.mr_notes}"
  end

  # A stale hold from another pipeline is released by a round that fixes.
  def test_a_round_that_fixes_releases_a_stale_hold
    client = FakeClient.new
    two_red_jobs(client)
    mon, = monitor(client)
    issue = watched_issue(target_red_hold_pipeline_id: 5000, target_red_hold_key: 'stale')

    mon.check(issue)

    assert_equal [nil, nil], [issue.reload.target_red_hold_pipeline_id, issue.target_red_hold_key]
  end

  # Matched by name: the target's `lint`, failing on the very examples `test`
  # fails on here, is not `test` — whose own failure on the target is another one.
  def test_the_target_job_is_found_by_name
    client = preexisting_client
    client.target_jobs[TARGET_PIPELINE].unshift(RedTargetFixtures.job(100, 'lint'))
    client.traces[100] = SPEC_FAILURE
    client.traces[101] = GIT_FAILURE
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_equal [['test']], calls[:fixed]
  end

  # The same red jobs served in another order are the same hold.
  def test_the_hold_key_does_not_depend_on_the_job_order
    client = preexisting_client
    add_held_lint_job(client)
    mon, _, issue = held(client)
    reads = client.trace_reads
    client.mr_jobs.reverse!

    mon.check(issue)

    assert_equal reads, client.trace_reads
  end

  # The newest finished pipeline may sit behind running ones: the scan goes
  # TARGET_PIPELINES_SCANNED deep.
  def test_the_scan_reaches_past_running_pipelines
    client = preexisting_client
    running = (1..5).map { |i| FakeClient::GlPipeline.new(id: 9100 + i, status: 'running', web_url: 'r') }
    client.target_pipelines = running + client.target_pipelines
    mon, calls = monitor(client)

    mon.check(watched_issue)

    assert_empty calls[:fixed]
  end

  # The merge request's own target, never the configuration's (Autodev #91):
  # powerpanne moved `staging` → `master` with 83 merge requests still on
  # `staging`. The fake raises on any ref but the merge request's.
  def test_the_target_compared_is_the_merge_requests_not_the_configurations
    client = preexisting_client
    mon, calls = monitor(client, project_config: PROJECT_CONFIG.merge('target_branch' => 'staging'))

    mon.check(watched_issue)

    assert_equal [[], 1], [calls[:fixed], client.mr_notes.size]
  end

  # One comment per pipeline *and* job set: the target coming to explain one more
  # job of the same pipeline is said too.
  def test_a_new_job_set_on_the_same_pipeline_comments_again
    client = FakeClient.new
    two_red_jobs(client)
    mon, = monitor(client)
    issue = watched_issue
    mon.check(issue)
    target_explains_both(client)

    mon.check(issue.reload)

    assert_equal 2, client.mr_notes.size
  end

  [Net::ReadTimeout.new, EOFError.new, FakeClient.response_error(502)].each do |error|
    define_method(:"test_a_comment_lost_to_#{error.class.name.gsub('::', '_')}_does_not_fail_the_poll") do
      client = preexisting_client
      client.failures[:mr_note] = error
      _, _, issue = held(client)

      assert_equal ['checking_pipeline', nil], [issue.status, issue.preexisting_noted_key]
    end
  end
end

# The hold's own clock (owner's decision of 09/10/2026). It used to be the
# watch's: `checking_pipeline_since`, so a row already watched for longer than
# `pipeline_watch_max_days` gave up on the very poll its hold began, having
# waited for nothing — the shape of powerpanne 16735, given up on 16/09/2026.
class TargetRedHoldClockTest < Minitest::Test
  include DatabaseTestHelper
  include PreexistingEdgeHelpers

  def setup = setup_database

  def test_a_hold_that_begins_on_an_old_watch_waits_the_full_bound
    client = preexisting_client
    mon, = monitor(client)
    issue = watched_issue(since: 60.days.ago)

    mon.check(issue)

    assert_equal 'checking_pipeline', issue.reload.status, 'the hold gave up on the poll it began'
    assert_in_delta Time.current, issue.target_red_hold_since, 5
  end

  def test_a_hold_that_goes_on_keeps_the_time_it_began
    client = preexisting_client
    began = 3.days.ago.change(usec: 0)
    mon, = monitor(client)
    issue = watched_issue(**hold_begun(began))

    mon.check(issue)

    assert_equal ['checking_pipeline', began], [issue.reload.status, issue.target_red_hold_since]
  end

  # The young watch clock does not save a hold whose own clock ran out.
  def test_a_hold_past_the_bound_gives_up_whatever_the_watch_clock_says
    client = preexisting_client
    mon, = monitor(client)
    issue = watched_issue(since: 1.day.ago, **hold_begun(15.days.ago))

    mon.check(issue)

    assert_equal %w[done target_pipeline_red], [issue.reload.status, issue.attention_reason]
  end

  def test_zero_days_still_disables_the_hold_bound
    client = preexisting_client
    mon, = monitor(client, project_config: PROJECT_CONFIG.merge('pipeline_watch_max_days' => 0))
    issue = watched_issue(since: 90.days.ago, **hold_begun(90.days.ago))

    mon.check(issue)

    assert_equal 'checking_pipeline', issue.reload.status
  end

  def test_the_target_recovering_clears_the_hold_clock
    client = preexisting_client
    mon, _, issue = held(client)
    recover_target(client)

    mon.check(issue)

    assert_nil issue.reload.target_red_hold_since
  end

  def test_a_round_that_fixes_clears_the_hold_clock
    client = FakeClient.new
    two_red_jobs(client)
    mon, = monitor(client)
    issue = watched_issue(target_red_hold_pipeline_id: 5000, target_red_hold_key: 'stale',
                          target_red_hold_since: 2.days.ago)

    mon.check(issue)

    assert_nil issue.reload.target_red_hold_since
  end

  # The give-up ends the hold's clock but keeps the held pipeline: a row put
  # back on track (starting label, reassigned) whose target is repaired by then
  # retries that pipeline, and one whose target is still red holds again for a
  # whole bound instead of giving up on its first poll.
  def test_the_give_up_ends_the_hold_clock_and_keeps_the_held_pipeline
    client = preexisting_client
    mon, = monitor(client)
    issue = held_since(15.days.ago)

    mon.check(issue)

    assert_equal ['done', nil, MR_PIPELINE],
                 [issue.reload.status, issue.target_red_hold_since, issue.target_red_hold_pipeline_id]
  end
end

# The way out of a `target_pipeline_red` give-up (owner's decision of
# 09/10/2026). Retrying the merge request pipeline is not one: no automatic pass
# re-selects a row given up under this reason, so autodev would never review nor
# deliver the merge request. The way out is every other give-up's.
class TargetRedGiveUpWayOutTest < Minitest::Test
  LOCALES = File.expand_path('../config/locales', __dir__)

  TEXTS = {
    %w[notifications fr target_pipeline_red] => 'remettez le label de depart et reassignez-moi',
    %w[notifications en target_pipeline_red] => 'put the starting label back and reassign me',
    %w[web fr web_errors_explain_attention_target_pipeline_red] => 'remettez le label de départ et réassignez Autodev',
    %w[web en web_errors_explain_attention_target_pipeline_red] => 'put the starting label back and reassign Autodev'
  }.freeze

  RETRY = /relance[rz]? la pipeline|retry the merge request pipeline/i

  def text(table, locale, key)
    YAML.load_file(File.join(LOCALES, "#{table}.#{locale}.yml")).fetch(locale).fetch(key)
  end

  TEXTS.each do |(table, locale, key), way_out|
    define_method(:"test_#{table}_#{locale}_gives_the_usual_way_out") do
      body = text(table, locale, key)

      assert_includes body, way_out
      refute_match RETRY, body, 'a pipeline retry does not bring autodev back'
    end
  end
end

# Phase-10 review of the alpha-57 lot. A row watched for 60 days holds, then
# the target is repaired: the retry released the hold, the poll no longer held,
# so the bound read `checking_pipeline_since` — 60 days — and the same poll gave
# the row up under `pipeline_watch_expired`, "never able to conclude", on the
# poll that had just concluded. The wait was the target's; the retried
# pipeline is a new one to watch.
class AReleasedHoldStartsANewWatchTest < Minitest::Test
  include DatabaseTestHelper
  include PreexistingEdgeHelpers
  include ActiveSupport::Testing::TimeHelpers

  def setup = setup_database

  def held_on_an_old_watch_then_retried(client)
    mon, = monitor(client)
    issue = watched_issue(since: 60.days.ago)
    mon.check(issue)
    recover_target(client)
    monitor(client).first.check(issue.reload)
    issue.reload
  end

  def poll(client, issue)
    monitor(client).first.check(issue.reload)
    issue.reload
  end

  def test_the_poll_that_retries_does_not_expire_the_watch_the_hold_waited_through
    client = preexisting_client
    issue = held_on_an_old_watch_then_retried(client)

    assert_equal ['checking_pipeline', nil, [MR_PIPELINE]], [issue.status, issue.attention_reason, client.retries]
    assert_in_delta Time.current.to_f, issue.checking_pipeline_since.to_f, 5
  end

  def test_the_retried_pipeline_is_watched_for_the_whole_bound_from_the_release
    client = preexisting_client
    issue = held_on_an_old_watch_then_retried(client)
    client.head = FakeClient::GlPipeline.new(id: MR_PIPELINE, status: 'running')

    travel 13.days

    assert_equal 'checking_pipeline', poll(client, issue).status, 'expired inside the bound counted from the release'

    travel 2.days

    assert_equal %w[done pipeline_watch_expired], [poll(client, issue).status, issue.attention_reason]
  end
end

# Phase-10 review of the alpha-57 lot. A round that fixes its own jobs left a
# recorded hold behind — pipeline, key and `target_red_hold_since` — and a
# later hold took that stale date for its own start, so it could be given up on
# its very first poll. Any poll that does not hold releases a recorded hold.
class APollThatDoesNotHoldReleasesTheHoldTest < Minitest::Test
  include DatabaseTestHelper
  include PreexistingEdgeHelpers

  def setup = setup_database

  # The target is green on `test`: the job is the merge request's own.
  def fixing_round_over_a_stale_hold(client)
    client.target_jobs[TARGET_PIPELINE] = [RedTargetFixtures.job(101, 'test', status: 'success')]
    mon, calls = monitor(client)
    issue = watched_issue(target_red_hold_pipeline_id: 5000, target_red_hold_key: 'stale',
                          target_red_hold_since: 20.days.ago)
    mon.check(issue)
    [mon, calls, issue.reload]
  end

  # A new merge request pipeline red on `test`, and `master` red on it again
  # for the same reason.
  def red_on_both_again(client)
    client.target_jobs[TARGET_PIPELINE] = [RedTargetFixtures.job(101, 'test')]
    client.head = FakeClient::GlPipeline.new(id: 5002, status: 'failed')
    client.mr_jobs = [RedTargetFixtures.job(4, 'test')]
    client.traces[4] = SPEC_FAILURE
  end

  def test_a_round_that_fixes_its_own_jobs_clears_the_hold
    client = preexisting_client
    _, calls, issue = fixing_round_over_a_stale_hold(client)

    assert_equal [[['test']], nil, nil, nil],
                 [calls[:fixed], issue.target_red_hold_pipeline_id, issue.target_red_hold_key,
                  issue.target_red_hold_since]
  end

  def test_a_later_hold_starts_its_own_clock_and_is_not_given_up_on_its_first_poll
    client = preexisting_client
    mon, _, issue = fixing_round_over_a_stale_hold(client)
    red_on_both_again(client)

    mon.check(issue)

    assert_equal ['checking_pipeline', 5002], [issue.reload.status, issue.target_red_hold_pipeline_id]
    assert_in_delta Time.current.to_f, issue.target_red_hold_since.to_f, 5
  end
end
