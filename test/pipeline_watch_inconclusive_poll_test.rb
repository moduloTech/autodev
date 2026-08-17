# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/pipeline_monitor'

# Autodev #56 — the age bound must only fire on a poll that actually read a
# pipeline verdict.
#
# Autodev #53 placed `abandon_expired_watch` as the last statement of the poll so
# that "the poll ended without a transition" would be a condition rather than an
# enumeration of the branches that go nowhere. Its design spec then claimed a
# GitLab outage could never trigger it: "check raises before reaching the call,
# and the rescue logs and returns". Autodev #51, merged in parallel, made that
# false — `fetch_pipeline_jobs` rescued the API error *internally* and returned
# nil, so `dispatch_blocked` returned normally and control reached the bound.
#
# Three shapes end a poll without concluding anything, and since Autodev #62 they
# are held by two different mechanisms:
#
#   1. `manual` / `skipped`, jobs endpoint unreachable (Autodev #51);
#   2. `failed`, jobs endpoint unreachable — `fetch_failed_jobs` used to swallow
#      the error into `[]`, which read as `handle_no_failed_jobs` (pre-existing);
#
#      Both of these now **abort** the poll with `ApiUnavailableError`, so control
#      never reaches the bound at all — #53's spec is true again by construction
#      rather than by a flag that has to be raised at each swallowing site.
#
#   3. a Claude quota outage, on either deferral — the poll read GitLab fine and
#      returns normally, so this is the case the flag still answers.
#
# The assertions below are the same either way: the row is left alone. They are
# deliberately written against the outcome, not the mechanism.
#
# Giving a 14-day-old ticket up costs a terminal status, `needs_attention`, an
# end label on GitLab and a public comment — and `pipeline_watch_expired` is
# excluded from `dispatch_infra_recheck`, so nothing re-arms the row. An
# infrastructure failure must never be the reason.
#
# The control tests at the bottom pin what must NOT change: a poll that DID read
# a status and simply had nothing to do is still abandoned. That is #53's whole
# safety net.
class PipelineWatchInconclusivePollTest < Minitest::Test
  FakePipeline = Struct.new(:id, :status)
  FakeMr = Struct.new(:state, :head_pipeline)

  # Gitlab::Error::ResponseError builds its message from the real HTTP response,
  # and the rescues under test are narrow — a plain Gitlab::Error::Error would
  # not exercise them.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Records `update` writes; the readers reflect them so the post-dispatch guard
  # sees what the real AASM object would carry.
  #
  # `abandon!` stands in for the AASM event the give-up path fires since Autodev
  # #60, including the `stamp_pipeline_watch!` callback that clears the watch
  # clock. The from-state restriction is reproduced too: the real event only
  # transitions out of `checking_pipeline` / `fixing_discussions`. Same shape as
  # the fake in test/pipeline_watch_bound_test.rb; the real machine's behaviour is
  # pinned against real AR rows in test/issue_abandonment_test.rb.
  class FakeIssue
    ABANDONABLE = %w[checking_pipeline fixing_discussions].freeze

    attr_reader :attrs, :issue_iid, :mr_iid, :mr_url, :review_count,
                :checking_pipeline_since, :pipeline_poll_since, :pipeline_retrigger_count,
                :stagnation_signatures, :issue_author_id
    # No `_max_review_rounds_reached`: Autodev #60 removed both the production
    # attr_writer and the `max_review_rounds_reached?` guard that read it, so a fake
    # still advertising it would describe a contract the real Issue no longer has.
    attr_accessor :_review_count_zero, :_review_count_over_zero, :_unresolved_discussions_empty

    def initialize(status: 'checking_pipeline', since: 20.days.ago, review_count: 0)
      @attrs = { status: status }
      @checking_pipeline_since = since
      @review_count = review_count
      @pipeline_retrigger_count = 1 # already retriggered: never re-enter that branch
      @issue_iid = 15_894
      @mr_iid = 42
      @mr_url = 'http://gitlab/mr/42'
      @issue_author_id = 7
    end

    # rubocop:disable Naming/PredicateMethod -- mirrors AASM's bang event, which
    # returns whether the transition happened.
    def abandon!
      return false unless ABANDONABLE.include?(status)

      @attrs[:status] = 'done'
      @checking_pipeline_since = nil
      true
    end
    # rubocop:enable Naming/PredicateMethod

    def update(hash)
      @attrs.merge!(hash)
      @checking_pipeline_since = hash[:checking_pipeline_since] if hash.key?(:checking_pipeline_since)
      @pipeline_poll_since = hash[:pipeline_poll_since] if hash.key?(:pipeline_poll_since)
      @stagnation_signatures = hash[:stagnation_signatures] if hash.key?(:stagnation_signatures)
      self
    end

    def status = @attrs[:status]
    def needs_attention = @attrs[:needs_attention]
    def attention_reason = @attrs[:attention_reason]
    def finished_at = @attrs[:finished_at]
  end

  # One open MR whose head pipeline carries `status`; the jobs endpoint either
  # answers `jobs` or fails the way GitLab fails.
  class StubClient
    def initialize(status:, jobs: [], raise_jobs: false)
      @pipeline = FakePipeline.new(215_229, status)
      @jobs = jobs
      @raise_jobs = raise_jobs
    end

    def merge_request(_path, _iid) = FakeMr.new('opened', @pipeline)

    def pipeline_jobs(_path, _pid, **_opts)
      raise Gitlab::Error::ResponseError, response if @raise_jobs

      @jobs
    end

    private

    def response
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/jobs'))
    end
  end

  NOOPS = %i[log log_error].freeze

  def monitor(client:, claude: true)
    sink = { notify: [], activity: [], labels: [], reassigned: [] }
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, client)
    mon.instance_variable_set(:@project_path, 'group/project')
    mon.instance_variable_set(:@project_config, {})
    mon.instance_variable_set(:@config, {})
    NOOPS.each { |noop| mon.define_singleton_method(noop) { |*| nil } }
    mon.define_singleton_method(:claude_available?) { claude }
    stub_sinks(mon, sink)
    [mon, sink]
  end

  # Every point at which the give-up path leaves the process: the GitLab label,
  # the assignee (Autodev #60), the issue comment and the activity log.
  def stub_sinks(mon, sink)
    mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
    stub_label_writers(mon, sink)
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:reassign_to_author) { |issue| sink[:reassigned] << issue.issue_iid }
  end

  # `label_attention` since Autodev #63; both land in the same sink because what
  # this file asserts is that an inconclusive poll writes *no* end label at all.
  def stub_label_writers(mon, sink)
    mon.define_singleton_method(:apply_label_attention) { |iid| sink[:labels] << iid }
    mon.define_singleton_method(:apply_label_done) { |iid| sink[:labels] << iid }
  end

  # Runs a whole poll through the real entry point, so the flag's lifetime (set
  # deep in the poll, read by the bound, reset on the next `check`) is exercised
  # rather than simulated.
  def poll(status:, jobs: [], raise_jobs: false, claude: true, issue: nil)
    issue ||= FakeIssue.new
    mon, sink = monitor(client: StubClient.new(status: status, jobs: jobs, raise_jobs: raise_jobs),
                        claude: claude)
    mon.check(issue)
    [issue, sink, mon]
  end

  def code_failure_jobs
    [{ 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
       'allow_failure' => false, 'failure_reason' => 'script_failure' }]
  end

  def assert_watch_kept(issue, sink)
    assert_equal 'checking_pipeline', issue.status, 'an inconclusive poll must leave the row alone'
    assert_empty sink[:notify], 'no give-up comment may be posted'
    assert_empty sink[:labels], 'no end label must be applied'
  end

  # --- 1. the jobs endpoint is unreachable on a manual pipeline ------------

  def test_an_unreachable_jobs_endpoint_on_a_manual_pipeline_does_not_abandon
    issue, sink = poll(status: 'manual', raise_jobs: true)

    assert_watch_kept(issue, sink)
  end

  def test_an_unreachable_jobs_endpoint_on_a_skipped_pipeline_does_not_abandon
    issue, sink = poll(status: 'skipped', raise_jobs: true)

    assert_watch_kept(issue, sink)
  end

  # --- 2. the jobs endpoint is unreachable on a red pipeline ---------------

  # `fetch_failed_jobs` used to answer an API error with `[]`, indistinguishable
  # from "nothing blocking failed" at the call site — so the poll logged "staying
  # in checking_pipeline" and the bound fired behind it. Since Autodev #62 the read
  # raises and `handle_red` never gets a list to misread.
  def test_an_unreachable_jobs_endpoint_on_a_red_pipeline_does_not_abandon
    issue, sink = poll(status: 'failed', raise_jobs: true)

    assert_watch_kept(issue, sink)
  end

  # --- 3. the Claude quota is exhausted -----------------------------------

  # The case the #53 spec documented as accepted: a pipeline that just turned
  # green on day 15, during an outage, was abandoned.
  def test_a_green_pipeline_deferred_for_quota_does_not_abandon
    issue, sink = poll(status: 'success', claude: false)

    assert_watch_kept(issue, sink)
  end

  def test_a_red_pipeline_deferred_for_quota_does_not_abandon
    issue, sink = poll(status: 'failed', jobs: code_failure_jobs, claude: false)

    assert_watch_kept(issue, sink)
  end

  # --- the flag's lifetime -------------------------------------------------

  # It is per-poll, not per-monitor: the same instance serves the next cycle.
  def test_a_later_conclusive_poll_on_the_same_monitor_still_abandons
    issue, _sink, mon = poll(status: 'manual', raise_jobs: true)

    assert_equal 'checking_pipeline', issue.status
    mon.instance_variable_set(:@client, StubClient.new(status: 'canceled'))
    mon.check(issue)

    assert_equal 'done', issue.status
  end

  # --- controls: #53's safety net must keep working ------------------------

  def test_a_canceled_pipeline_is_still_abandoned
    issue, sink = poll(status: 'canceled')

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
    refute_empty sink[:notify]
  end

  # A pipeline stuck at `created` for a fortnight is the shape #53 was built for.
  def test_a_pipeline_stuck_running_is_still_abandoned
    issue, = poll(status: 'created')

    assert_equal 'done', issue.status
  end

  # The jobs endpoint answered; nothing blocking failed; the poll concluded
  # "green" and transitioned. Reading a verdict is exactly what the bound wants,
  # and the transition is what stops it — unchanged since #53.
  def test_a_manual_pipeline_read_successfully_is_resolved_not_abandoned
    issue = FakeIssue.new
    issue.define_singleton_method(:pipeline_green!) { update(status: 'reviewing') }
    jobs = [{ 'name' => 'deploy_review', 'stage' => 'deploy', 'status' => 'manual', 'allow_failure' => false }]
    mon, sink = monitor(client: StubClient.new(status: 'manual', jobs: jobs))
    mon.define_singleton_method(:launch_review) { |_issue| nil }
    mon.check(issue)

    assert_equal 'reviewing', issue.status
    assert_empty sink[:notify]
  end
end

# The second half of Autodev #56: the abandon message must not lie.
#
# The bound fires on any watch that went nowhere for a fortnight, which includes
# a pipeline that moved plenty — an infra failure recurring with a fresh
# signature every day never transitions either, and neither does a pipeline that
# turned green during a Claude quota outage. "The pipeline has not moved for more
# than 14 days" was factually wrong in exactly the cases that reach here.
class PipelineWatchExpiredMessageTest < Minitest::Test
  def test_the_gitlab_comment_does_not_claim_the_pipeline_stopped_moving
    fr = Locales.t(:pipeline_watch_expired, locale: :fr, tag: 't', mr_url: 'url', days: 14)
    en = Locales.t(:pipeline_watch_expired, locale: :en, tag: 't', mr_url: 'url', days: 14)

    refute_match(/n'a pas evolue|sans evolution/, fr)
    refute_match(/has not moved|unchanged/, en)
  end

  def test_the_gitlab_comment_names_the_watch_duration_in_both_locales
    %i[fr en].each do |loc|
      msg = Locales.t(:pipeline_watch_expired, locale: loc, tag: 't', mr_url: 'url', days: 14)

      assert_includes msg, '14', "#{loc}: the age that triggered the give-up must be stated"
      assert_includes msg, 'url', "#{loc}: the MR must stay reachable from the comment"
    end
  end

  def test_the_activity_line_does_not_claim_the_pipeline_stopped_moving
    fr = Locales.t(:activity_pipeline_watch_expired, locale: :fr, tag: 't', days: 14)
    en = Locales.t(:activity_pipeline_watch_expired, locale: :en, tag: 't', days: 14)

    refute_match(/sans evolution|n'a pas evolue/, fr)
    refute_match(/unchanged|has not moved/, en)
    [fr, en].each { |msg| assert_includes msg, '14' }
  end

  def test_the_web_explanation_does_not_claim_the_pipeline_stopped_moving
    fr = Locales.t(:web_errors_explain_attention_pipeline_watch_expired, locale: :fr)
    en = Locales.t(:web_errors_explain_attention_pipeline_watch_expired, locale: :en)

    refute_match(/n'a plus évolué|n'a pas évolué/, fr)
    refute_match(/stopped moving|never changed/, en)
  end
end
