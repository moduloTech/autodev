# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'

# What label does an abandoned ticket end up carrying? (Autodev #63)
#
# Every give-up path used to call `apply_label_done`, and on the projects that
# matter `label_done` is `Development::Awaiting Feature Review` — "ready for
# feature review". So a ticket autodev failed to review five times, or gave up on
# after five identical infra failures, arrived on the PM's board presented as
# reviewed. That is one of the mechanisms that filled the review board during the
# 11/08/2026 incident: 28 tickets pushed to `Development::Awaiting Feature
# Review`, three quarters of them in merge conflict, none of them reviewed.
#
# The end label is now `label_attention` — a third, optional value in the
# project's own workflow scope. When the project does not declare one, no end
# label is applied at all and the row keeps `label_doing`: a ticket that looks
# still-in-progress is less wrong than a ticket that looks reviewed.
#
# The comment and the `attention_reason` stay per-reason (Autodev #60) — only the
# label is uniform, across all six give-up paths (five at #63, plus the MR closed
# without merging that Autodev #66 routed here).
class AbandonAttentionLabelTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  # The real powerpanne/core shape: `label_done` is the "ready for feature
  # review" column, which is exactly why it must not be what an abandon poses.
  BASE_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                  'label_doing' => 'Development::Doing',
                  'label_done' => 'Development::Awaiting Feature Review' }.freeze
  ATTENTION = 'Development::StandBy'
  WITH_ATTENTION = BASE_CONFIG.merge('label_attention' => ATTENTION).freeze

  # Records everything crossing the GitLab boundary so the real LabelManager /
  # IssueNotifier / ActivityLogger code runs.
  class FakeClient
    Issue = Struct.new(:labels, :id)
    Note = Struct.new(:id, :body)

    attr_reader :edits, :notes

    def initialize(labels = ['To do', 'Development::Doing'])
      @labels = labels
      @edits = []
      @notes = []
    end

    def issue(_path, _iid) = Issue.new(labels: @labels.dup, id: 1)
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

  def worker(klass = PipelineMonitor, project_config: BASE_CONFIG, config: {})
    klass.allocate.tap do |instance|
      instance.send(:init_runner, client: @client, config: config, project_config: project_config,
                                  logger: NullLogger.new, token: 'tok')
    end
  end

  def watched(**overrides)
    issue = create_issue(mr_iid: 7, mr_url: 'http://gitlab/mr/7', issue_author_id: 42,
                         locale: 'fr', **overrides)
    advance_to(issue, 'checking_pipeline')
    issue
  end

  # Every `labels:` payload the run sent to GitLab, newest last, split back into
  # the label list `manage_labels` joined.
  def labels_sent
    @client.edits.filter_map { |(_, attrs)| attrs[:labels]&.split(',') }
  end

  # --- the six give-up paths, one per test ----------------------------------
  #
  # Each fires the real entry point of its path, not `abandon_issue` directly, so
  # the test would still fail if a path stopped routing through the shared point.

  def stagnation_pipeline(project_config)
    issue = watched
    worker(project_config: project_config, config: { 'stagnation_threshold' => 1 })
      .send(:handle_stagnation, issue, :pipeline, detail: 'deploy_review')
    issue
  end

  def stagnation_discussions(project_config)
    issue = watched
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green! # → fixing_discussions
    worker(MrFixer, project_config: project_config).send(:transition_to_done_stagnation!, issue)
    issue
  end

  def pipeline_watch_expired(project_config)
    issue = watched
    issue.update_columns(checking_pipeline_since: 40.days.ago)
    worker(project_config: project_config).send(:abandon_expired_watch, issue)
    issue
  end

  def review_limit_reached(project_config)
    issue = watched
    issue.update_columns(review_count: 3)
    worker(project_config: project_config).send(:green_done_max_reviews, issue)
    issue
  end

  # The one give-up that starts from `reviewing` and keeps its own AASM event
  # (`review_giveup`) — the path Autodev #63 was filed against.
  def review_failures_exhausted(project_config)
    issue = watched
    issue._review_count_zero = true
    issue.pipeline_green! # → reviewing
    worker(project_config: project_config).send(:give_up_reviewing, issue)
    issue
  end

  # The sixth path, added by Autodev #66: a human closed the MR without merging
  # it. Not autodev's own verdict, but the same ending — nothing was delivered, so
  # the end label must not read "ready for feature review" here either. The
  # merged-vs-closed split itself lives in `test/mr_closed_without_merge_test.rb`.
  CLOSED_MR = Struct.new(:state).new('closed')

  def mr_closed_unmerged(project_config)
    issue = watched
    worker(project_config: project_config).send(:handle_mr_closed, issue, CLOSED_MR)
    issue
  end

  PATHS = %i[stagnation_pipeline stagnation_discussions pipeline_watch_expired
             review_limit_reached review_failures_exhausted mr_closed_unmerged].freeze

  # --- with a `label_attention` configured ----------------------------------

  PATHS.each do |path|
    define_method(:"test_#{path}_poses_the_attention_label") do
      send(path, WITH_ATTENTION)

      assert_equal [[ATTENTION]], labels_sent,
                   "#{path} did not pose label_attention as the only label edit"
    end

    define_method(:"test_#{path}_never_poses_the_ready_for_review_label") do
      send(path, WITH_ATTENTION)

      refute_includes labels_sent.flatten, BASE_CONFIG['label_done'],
                      "#{path} presented an abandoned ticket as ready for feature review"
    end

    # The documented fallback (option 1 of the ticket): no end label at all, so
    # the row keeps `label_doing`. A ticket that still looks in progress is less
    # wrong than one that looks reviewed.
    define_method(:"test_#{path}_leaves_the_label_alone_with_no_attention_label") do
      send(path, BASE_CONFIG)

      assert_empty labels_sent, "#{path} edited the labels with no label_attention configured"
    end

    # The label is the only thing #63 changes: the row still ends `done` +
    # `needs_attention`, still hands the ticket back and still posts its own
    # comment.
    define_method(:"test_#{path}_still_flags_the_row_and_hands_it_back") do
      issue = send(path, WITH_ATTENTION)

      assert_equal ['done', true], [issue.reload.status, issue.needs_attention]
      assert_includes @client.edits.map(&:last), { assignee_ids: [42] }
      refute_empty @client.notes
    end
  end

  # --- what must NOT change -------------------------------------------------

  # A nominal delivery is still a delivery: `label_done` is what a reviewed,
  # green MR gets, and configuring `label_attention` must not touch that.
  def test_a_nominal_delivery_still_poses_label_done
    issue = watched
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = true
    issue.pipeline_green! # → done
    worker(project_config: WITH_ATTENTION).send(:finalize_green_done, issue, [])

    assert_equal [[BASE_CONFIG['label_done']]], labels_sent
  end

  # Applying `label_doing` or `label_done` clears a stale attention label, so a
  # row that was abandoned and then re-armed (`dispatch_infra_recheck` →
  # `resume_recovered_infra`) does not end up carrying two values of the same
  # GitLab scope.
  def test_applying_label_doing_clears_a_stale_attention_label
    @client = FakeClient.new([ATTENTION])
    worker(project_config: WITH_ATTENTION).send(:apply_label_doing, 7)

    assert_equal [['Development::Doing']], labels_sent
  end

  def test_applying_label_done_clears_a_stale_attention_label
    @client = FakeClient.new([ATTENTION])
    worker(project_config: WITH_ATTENTION).send(:apply_label_done, 7)

    assert_equal [[BASE_CONFIG['label_done']]], labels_sent
  end

  # A project with no label workflow at all is untouched by any of this — the
  # `label_workflow?` gate comes first.
  def test_no_label_workflow_poses_nothing
    stagnation_pipeline('path' => 'group/project', 'label_attention' => ATTENTION)

    assert_empty labels_sent
  end

  # A blank value is "not configured", not a label named "".
  def test_a_blank_attention_label_falls_back_to_leaving_the_label_alone
    stagnation_pipeline(BASE_CONFIG.merge('label_attention' => '   '))

    assert_empty labels_sent
  end
end
