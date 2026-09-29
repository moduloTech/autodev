# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'
require 'autodev/issue_processor'

# Autodev #128 — A#105 (POWERPANNE#15819), 09/06/2026: five public comments
# "échec de la correction du pipeline — Encoding::UndefinedConversionError" in
# eight minutes, one per poll.
#
# The error was raised inside `attempt_fix` but before `pipeline_failed_code!`,
# while the row was still `checking_pipeline`. `mark_failed` had no transition
# from there and `whiny_transitions: false` made the refusal silent, so
# `handle_failure_error` wrote its `error_message` and posted its comment on a
# row that had not moved — and `dispatch_pipelines` picked it up again next
# cycle. In June a stagnation bound stopped it at the sixth poll; since Autodev
# #71 the signature is written after the attempt, so nothing stopped it any more.
#
# Pinned here: the outcome of whole polls, over a real state machine and a real
# row. Stubbed: the clone, the job logs, the pre-triage and danger-claude.
class APipelineFailureLandsInErrorTest < Minitest::Test
  include DatabaseTestHelper

  FakePipeline = Struct.new(:id, :status)
  FakeMr = Struct.new(:state, :head_pipeline, :target_branch)
  CODE_JOBS = [{ 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
                 'allow_failure' => false, 'failure_reason' => 'script_failure' }].freeze

  class StubClient
    def merge_request(_path, _iid) = FakeMr.new('opened', FakePipeline.new(9, 'failed'), 'master')
    def pipeline_jobs(_path, _pid, **_opts) = CODE_JOBS
  end

  def setup
    setup_database
    @sink = { notify: [], activity: [], errors: [] }
  end

  def watched_row
    issue = create_issue(status: 'pending', mr_iid: 42, mr_url: 'http://gitlab/mr/42',
                         branch_name: 'autodev/1', issue_author_id: 7, review_count: 1)
    advance_to(issue, 'checking_pipeline')
    issue.reload
  end

  # `raise_at` names the stubbed step that raises, and `error` what it raises.
  # `write_and_categorize_jobs` is where A#105's encoding error came from: the
  # job logs are written before the fix is dispatched.
  def monitor(raise_at: :write_and_categorize_jobs,
              error: Encoding::UndefinedConversionError.new('"\xC3" from ASCII-8BIT to UTF-8'))
    mon = PipelineMonitor.allocate
    { :@client => StubClient.new, :@project_path => 'group/project', :@project_config => {},
      :@config => {}, :@dc_stdout => '', :@dc_stderr => '' }.each { |k, v| mon.instance_variable_set(k, v) }
    stub_fix_path(mon, raise_at, error)
    stub_sinks(mon)
    mon
  end

  def stub_fix_path(mon, raise_at, error)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :code, explanation: 'rspec is red' } }
    %i[prepare_work_dir write_and_categorize_jobs fix_each_job push_fixes].each do |step|
      mon.define_singleton_method(step) { |*| step == raise_at ? raise(error) : [] }
    end
  end

  def stub_sinks(mon)
    sink = @sink
    mon.define_singleton_method(:log) { |*| nil }
    mon.define_singleton_method(:log_error) { |msg| sink[:errors] << msg }
    mon.define_singleton_method(:log_activity) { |_i, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
  end

  def fix_error_comments = @sink[:notify].count { |key, _| key == :pipeline_fix_error }

  # What `dispatch_pipelines` does each cycle: every `checking_pipeline` row with
  # a merge request gets one `check`. That selection is the whole of the loop.
  def poll_cycle
    Issue.where(status: 'checking_pipeline').where.not(mr_iid: nil).find_each { |row| monitor.check(row) }
  end

  # --- the defect -----------------------------------------------------------

  def test_a_failure_before_the_fix_lands_the_row_in_error
    issue = watched_row

    monitor.check(issue)
    issue.reload

    assert_equal 'error', issue.status
    assert_nil issue.next_retry_at, 'no retry is scheduled: the dormant audit re-arms it'
    assert_nil issue.checking_pipeline_since
  end

  def test_the_failure_is_recorded_and_announced_once
    issue = watched_row

    monitor.check(issue)

    assert_match(/\APipeline fix error: Encoding::UndefinedConversionError/, issue.reload.error_message)
    assert_equal 1, fix_error_comments
  end

  def test_two_poll_cycles_post_a_single_failure_comment
    watched_row

    2.times { poll_cycle }

    assert_equal 1, fix_error_comments, "one comment per real failure, not per poll: #{@sink[:notify].inspect}"
    assert_equal(1, @sink[:activity].count { |key, _| key == :error })
  end

  # The row must not be stranded either: once its activity has aged past the
  # window, it is in the population the dormant audit's error arm re-arms.
  def test_the_errored_row_is_one_the_dormant_audit_recovers
    issue = watched_row
    monitor.check(issue)

    audit = Autodev::DormantAudit.new(client: nil, path: 'group/project', config: {}, project_config: {},
                                      logger: StubLogger.new, now: 3.days.from_now)

    assert_includes audit.send(:error_arm).pluck(:id), issue.id
  end

  # --- the other two handlers on the same path ------------------------------

  def test_a_rate_limit_during_the_evaluation_parks_the_row_until_the_reset
    issue = watched_row

    reset = 10.minutes.from_now
    monitor(raise_at: :prepare_work_dir, error: RateLimitError.new('quota', reset_time: reset)).check(issue)

    assert_equal 'error', issue.reload.status
    assert_in_delta reset.to_i, issue.next_retry_at.to_i, 60
    assert_equal 0, fix_error_comments
  end

  def test_an_authentication_failure_before_the_fix_lands_the_row_in_error
    issue = watched_row

    monitor(raise_at: :prepare_work_dir, error: AuthenticationError.new('401')).check(issue)

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  # --- a human gesture still holds (Autodev #97) ----------------------------

  # Closed from the dashboard while the clone ran: the transition is legal from
  # what this object believed, the row no longer holds it, so it is refused —
  # and the refusal now happens *before* the comment. It used to be a silent
  # no-op followed by a public failure comment on a closed ticket.
  def test_a_close_during_the_fix_is_neither_overwritten_nor_announced
    issue = watched_row
    Issue.where(id: issue.id).update_all(status: 'closed')

    monitor.check(issue)

    assert_equal 'closed', issue.reload.status
    assert_nil issue.error_message
    assert_equal 0, fix_error_comments
  end
end

# The other half of Autodev #128: a `mark_failed` the state machine refuses
# writes nothing and posts nothing, on every one of the nine handlers that
# funnel through `safe_mark_failed!`. `needs_clarification` is the refused state
# a worker can really reach (IssueProcessor, a write raising after
# `spec_unclear!`), and it is exactly where a failure comment would sit right
# under the questions the requester was just asked (Autodev #75).
class ARefusedFailureWritesNothingTest < Minitest::Test
  include DatabaseTestHelper

  # Records every GitLab call, so "nothing posted" is a count, not a hope.
  class RecordingClient
    attr_reader :calls

    def initialize = @calls = []

    def method_missing(name, *, **)
      @calls << name
      nil
    end

    def respond_to_missing?(*) = true
  end

  HANDLERS = {
    PipelineMonitor => %i[handle_rate_limit handle_auth_failure handle_failure_error],
    MrFixer => %i[handle_rate_limit handle_auth_failure handle_fix_error],
    IssueProcessor => %i[handle_rate_limit handle_auth_failure handle_process_error]
  }.freeze

  def setup = setup_database

  def parked_row
    issue = create_issue(mr_iid: 42, retry_count: 0)
    advance_to(issue, 'checking_spec')
    issue.spec_unclear!
    issue.reload
  end

  def worker(klass, client)
    w = klass.allocate
    { :@project_path => 'group/project', :@project_config => {}, :@config => {}, :@client => client,
      :@logger => StubLogger.new, :@dc_stdout => 'out', :@dc_stderr => 'err' }.each do |k, v|
      w.instance_variable_set(k, v)
    end
    w
  end

  def error_for(handler)
    case handler
    when :handle_rate_limit then RateLimitError.new('quota')
    when :handle_auth_failure then AuthenticationError.new('401')
    else RuntimeError.new('boom')
    end
  end

  HANDLERS.each do |klass, handlers|
    handlers.each do |handler|
      define_method(:"test_#{klass.name.underscore}_#{handler}_writes_nothing_on_a_refused_transition") do
        issue = parked_row
        before = issue.attributes.except('updated_at')
        activity = ActivityEvent.where(issue_id: issue.id).count
        client = RecordingClient.new

        worker(klass, client).send(handler, issue, error_for(handler))

        assert_equal before, issue.reload.attributes.except('updated_at')
        assert_equal activity, ActivityEvent.where(issue_id: issue.id).count
        assert_empty client.calls, "#{klass}##{handler} reached GitLab on a refused transition"
      end
    end
  end
end
