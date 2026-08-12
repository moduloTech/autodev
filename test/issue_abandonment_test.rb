# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'

# The single point at which autodev gives a ticket up (Autodev #60, item 2).
#
# There used to be three (four, counting the discussions twin) and they diverged
# on two axes:
#
#   * `handle_stagnation`, `give_up_on_watch` and
#     `MrFixer#transition_to_done_stagnation!` wrote `status: 'done'` straight to
#     the row. No AASM event means no `transition` row in `activity_events`, so no
#     entry in the activity journal and none in the audit log — and none of the
#     `after_all_transitions` callbacks ran, which is precisely what produced the
#     stale `checking_pipeline_since` clock Autodev #53 had to fix by hand at each
#     of those call sites.
#   * the review-rounds path reassigned the ticket to its author; the other three
#     left it assigned to autodev, which made an abandoned ticket invisible to
#     everybody.
#
# All of them now go through `abandon_issue`, one AASM `abandon` event and one
# reassignment policy. What must NOT be unified is `attention_reason`:
# `dispatch_infra_recheck` selects `stagnation_pipeline` and would re-arm rows
# abandoned for any other cause.
class IssueAbandonmentTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Doing', 'label_done' => 'Done' }.freeze

  # Records everything that crosses the GitLab boundary, so the real
  # LabelManager / IssueNotifier / ActivityLogger code paths run.
  class FakeClient
    Issue = Struct.new(:labels, :id)
    Note = Struct.new(:id, :body)

    attr_reader :edits, :notes

    def initialize
      @edits = []
      @notes = []
    end

    def issue(_path, _iid) = Issue.new(labels: ['To do', 'Doing'], id: 1)
    def user = Issue.new(labels: [], id: 999)

    def edit_issue(_path, iid, **attrs)
      @edits << [iid, attrs]
      Issue.new(labels: [], id: 1)
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      Note.new(id: @notes.size, body: body)
    end

    def issue_note(_path, _iid, note_id) = Note.new(id: note_id, body: @notes.last.to_s)

    def edit_issue_note(_path, _iid, _note_id, body)
      @notes[-1] = body
      Note.new(id: 1, body: body)
    end
  end

  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  def setup
    setup_database
    @client = FakeClient.new
  end

  def worker(klass = PipelineMonitor, config: {})
    klass.allocate.tap do |instance|
      instance.send(:init_runner, client: @client, config: config, project_config: PROJECT_CONFIG,
                                  logger: NullLogger.new, token: 'tok')
    end
  end

  def watched(**overrides)
    issue = create_issue(mr_iid: 7, mr_url: 'http://gitlab/mr/7', issue_author_id: 42,
                         locale: 'fr', **overrides)
    advance_to(issue, 'checking_pipeline')
    issue
  end

  def transitions_for(issue)
    ActivityEvent.where(issue_id: issue.id, kind: 'transition')
                 .map { |e| JSON.parse(e.payload_json)['event'] }
  end

  def abandon(issue, *, **)
    worker.send(:abandon_issue, issue, *, **)
  end

  # --- the AASM event ------------------------------------------------------

  def test_abandoning_emits_a_transition_row
    issue = watched
    abandon(issue, :stagnation_pipeline)

    assert_includes transitions_for(issue), 'abandon'
  end

  def test_abandoning_reaches_done_and_persists_it
    issue = watched
    abandon(issue, :stagnation_pipeline)

    assert_equal 'done', issue.reload.status
  end

  # The bug the stale-clock fix had to patch at each call site: the AASM callback
  # owns this column, so routing through the event makes the explicit clear at
  # every give-up site unnecessary — and impossible to forget at the next one.
  def test_the_aasm_callback_clears_the_watch_clock
    issue = watched

    refute_nil issue.checking_pipeline_since
    abandon(issue, :pipeline_watch_expired, days: 14)

    assert_nil issue.reload.checking_pipeline_since
  end

  def test_abandoning_writes_an_audit_row
    issue = watched
    abandon(issue, :stagnation_pipeline)

    assert_equal 1, AuditLog.where(resource_type: 'Issue', resource_id: issue.id,
                                   action: 'issue.transition_auto')
                            .where("payload LIKE '%\"event\":\"abandon\"%'").count
  end

  # A row already out of an abandonable state must not have the side effects
  # replayed on it — the Autodev #61 class of bug, which `whiny_transitions:
  # false` makes silent.
  def test_a_row_that_cannot_be_abandoned_gets_no_side_effects # rubocop:disable Minitest/MultipleAssertions
    issue = create_issue(status: 'done', mr_iid: 7, issue_author_id: 42)

    refute abandon(issue, :stagnation_pipeline)
    assert_empty @client.notes
    assert_empty @client.edits
    refute issue.reload.needs_attention
  end

  # --- the reassignment policy --------------------------------------------

  def test_every_reason_reassigns_the_ticket_to_its_author
    %i[stagnation_pipeline stagnation_discussions pipeline_watch_expired review_limit_reached]
      .each do |reason|
      @client = FakeClient.new
      issue = watched
      abandon(issue, reason, days: 14)

      assert_includes @client.edits.map(&:last), { assignee_ids: [42] },
                      "#{reason} did not reassign to the author"
    end
  end

  def test_an_authorless_ticket_is_abandoned_without_a_reassignment
    issue = watched(issue_author_id: nil)
    abandon(issue, :stagnation_pipeline)

    assert_equal 'done', issue.reload.status
    assert_empty(@client.edits.map(&:last).select { |a| a.key?(:assignee_ids) })
  end

  def test_the_gitlab_comment_says_the_ticket_was_handed_back
    issue = watched
    abandon(issue, :stagnation_pipeline, detail: 'deploy_review (script_failure)')

    assert_includes @client.notes.first, Locales.t(:abandon_reassigned, locale: :fr)
  end

  def test_no_handback_sentence_when_there_was_nobody_to_hand_back_to
    issue = watched(issue_author_id: nil)
    abandon(issue, :stagnation_pipeline)

    refute_includes @client.notes.first, Locales.t(:abandon_reassigned, locale: :fr)
  end

  # --- the reasons stay distinguishable -----------------------------------

  def test_each_reason_is_recorded_verbatim_on_the_row
    { stagnation_pipeline: 'stagnation_pipeline',
      stagnation_discussions: 'stagnation_discussions',
      pipeline_watch_expired: 'pipeline_watch_expired',
      review_limit_reached: 'review_limit_reached' }.each do |reason, expected|
      issue = watched
      abandon(issue, reason, days: 14)

      assert_equal [true, expected], [issue.reload.needs_attention, issue.attention_reason]
    end
  end

  # The load-bearing distinction: `dispatch_infra_recheck` selects exactly
  # `stagnation_pipeline` and re-arms the row. If an expired watch or an
  # exhausted review budget carried that reason, autodev would restart tickets it
  # had just given up on.
  def test_only_a_pipeline_stagnation_is_a_candidate_for_the_infra_recheck
    reasons = %i[stagnation_pipeline stagnation_discussions pipeline_watch_expired
                 review_limit_reached]
    reasons.each do |reason|
      issue = watched
      abandon(issue, reason, days: 14)
    end

    rearmed = Issue.where(status: 'done', needs_attention: true,
                          attention_reason: 'stagnation_pipeline').count

    assert_equal 1, rearmed
  end

  # --- the reason-specific messages survive the unification ---------------

  def test_the_message_stays_specific_to_the_reason
    detail = 'deploy_review (script_failure)'
    issue = watched
    abandon(issue, :stagnation_pipeline, detail: detail)

    assert_includes @client.notes.first, detail
    assert_includes @client.notes.first, 'http://gitlab/mr/7'
  end

  def test_the_expired_watch_message_carries_its_age
    issue = watched
    abandon(issue, :pipeline_watch_expired, days: 21)

    assert_includes @client.notes.first, '21'
  end

  def test_the_detail_is_persisted_for_the_dashboard
    issue = watched
    abandon(issue, :stagnation_pipeline, detail: 'werf_render')

    assert_equal 'werf_render', issue.reload.attention_detail
  end

  def test_a_reason_with_no_detail_leaves_the_column_null
    issue = watched
    abandon(issue, :review_limit_reached)

    assert_nil issue.reload.attention_detail
  end

  # --- the four call sites all land here ----------------------------------

  def test_pipeline_stagnation_goes_through_the_abandon_event
    issue = watched
    monitor = worker(PipelineMonitor, config: { 'stagnation_threshold' => 1 })
    monitor.send(:handle_stagnation, issue, :pipeline, detail: 'deploy_review')

    assert_equal ['done', true, 'stagnation_pipeline'],
                 [issue.reload.status, issue.needs_attention, issue.attention_reason]
    assert_includes transitions_for(issue), 'abandon'
  end

  def test_an_expired_watch_goes_through_the_abandon_event
    issue = watched
    issue.update_columns(checking_pipeline_since: 40.days.ago)
    worker.send(:abandon_expired_watch, issue)

    assert_equal %w[done pipeline_watch_expired],
                 [issue.reload.status, issue.attention_reason]
    assert_includes transitions_for(issue), 'abandon'
  end

  def test_the_review_round_limit_goes_through_the_abandon_event
    issue = watched
    issue.update_columns(review_count: 3)
    worker.send(:green_done_max_reviews, issue)

    assert_equal %w[done review_limit_reached],
                 [issue.reload.status, issue.attention_reason]
    assert_includes transitions_for(issue), 'abandon'
  end

  def test_discussion_stagnation_goes_through_the_abandon_event
    issue = watched
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green! # → fixing_discussions
    worker(MrFixer).send(:transition_to_done_stagnation!, issue)

    assert_equal %w[done stagnation_discussions],
                 [issue.reload.status, issue.attention_reason]
    assert_includes transitions_for(issue), 'abandon'
  end
end
