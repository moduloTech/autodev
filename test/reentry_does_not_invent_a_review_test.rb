# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# What does a reentry do to the count of reviews that actually happened?
# (Autodev #85)
#
# `ResumeHandler#reenter_via_pipeline_check` used to write `review_count: 1` flat,
# and the comment above it stated that as a decision. It is only true of the case
# it was written for: a *delivered* request whose todo label a human reposes. That
# one has been reviewed — `finalize_green_done` is reachable through
# `green_post_review` alone — so the 1 it is given is the 1 it already had, and
# what the line really buys is the cap: an inherited value at the review-round
# limit would otherwise send the next green pipeline straight to
# `green_done_max_reviews`.
#
# A request abandoned BEFORE any review carries `review_count = 0`, and 0 is a
# fact: nobody looked. Writing 1 over it makes `PipelineMonitor#green_branch`
# answer `:post_review` at the next green pipeline, so the review is skipped, the
# (empty, because no review ever opened one) discussion list reads as a clean MR,
# and the request ends `done` under `label_done` — `Development::Awaiting Feature
# Review` on powerpanne. Autodev announces as reviewed something no reviewer has
# seen. That is the exact harm Autodev #63 removed from the six abandon paths,
# put back by the reentry path.
#
# The population is not hypothetical: 43 reentries through this line in
# production, 11 of them on requests with no review at all, 7 already finished
# and mislabelled.
#
# Driven through `check` / `poll_open_mr` rather than `handle_green`, and the
# reentry itself through `PollRouter#route` rather than by writing the columns:
# the defect is in the routing, and a test that set the row up by hand would
# survive the routing changing underneath it.
class ReentryDoesNotInventAReviewTest < Minitest::Test
  include DatabaseTestHelper

  # The real powerpanne shape. `label_done` being the "ready for feature review"
  # column is what turns the extra review round into a false statement rather
  # than a wasted one.
  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review' }.freeze
  CONFIG = { 'gitlab_token' => 'tok', 'gitlab_url' => 'https://gitlab.example' }.freeze

  AUTHOR_ID = 42
  MR_IID = 7

  # Records everything crossing the GitLab boundary so the real PollRouter /
  # LabelManager / IssueNotifier / ActivityLogger code runs against it.
  class FakeClient
    GlIssue = Struct.new(:labels, :id)
    GlMr = Struct.new(:state, :head_pipeline)
    GlPipeline = Struct.new(:id, :status)
    Note = Struct.new(:id, :body)
    DiscussionNote = Struct.new(:resolvable, :resolved, :system, :created_at, :body)
    Discussion = Struct.new(:id, :notes)

    Paginated = Struct.new(:items) do
      def auto_paginate = items
    end

    attr_reader :edits, :notes

    def initialize(unresolved_discussions: 0)
      @unresolved = unresolved_discussions
      @edits = []
      @notes = []
    end

    def merge_request(_path, _iid) = GlMr.new(state: 'opened', head_pipeline: GlPipeline.new(id: 1, status: 'success'))
    def issue(_path, _iid) = GlIssue.new(labels: ['To do', 'Development::Doing'], id: 1)
    def user = GlIssue.new(labels: [], id: 999)
    def issue_notes(_path, _iid, **_opts) = Paginated.new([])

    def merge_request_discussions(_path, _iid, **_opts)
      threads = Array.new(@unresolved) do |i|
        Discussion.new(id: "d#{i}", notes: [DiscussionNote.new(resolvable: true, resolved: false, system: false,
                                                               created_at: '2026-08-01T10:00:00Z', body: 'finding')])
      end
      Paginated.new(threads)
    end

    def edit_issue(_path, iid, **attrs)
      @edits << [iid, attrs]
      GlIssue.new(labels: [], id: 1)
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

  # Records `info` because half of what Autodev #85 claims is a *log line*: the
  # reentry says which branch it is sending the request down, and that sentence
  # is the only trace an operator reading the worker log has of the decision.
  class NullLogger
    attr_reader :lines

    def initialize = @lines = []
    def info(msg, **) = @lines << msg.to_s
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  FakeGlIssue = Struct.new(:iid, :title)

  def setup
    setup_database
    @reviews = []
    @logger = NullLogger.new
  end

  # Step 1: a request that reached `done` and whose todo label a human reposes,
  # routed by the real `PollRouter`. `review_count` is what it carried when it
  # was given up.
  def reenter(review_count:, unresolved_discussions: 0)
    @client = FakeClient.new(unresolved_discussions: unresolved_discussions)
    issue = finished_row(review_count)
    router.route(FakeGlIssue.new(issue.issue_iid, 'a request'), @client)

    assert_equal 'checking_pipeline', issue.reload.status
    issue
  end

  # `done` with an open MR, carrying the review count it was given up with.
  def finished_row(review_count)
    issue = create_issue(mr_iid: MR_IID, mr_url: 'http://gitlab/mr/7',
                         issue_author_id: AUTHOR_ID, locale: 'fr', review_count: review_count)
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = true
    issue.pipeline_green!

    assert_equal 'done', issue.status
    issue
  end

  # Step 2: the next poll cycle on the re-entered row, pipeline green.
  def poll(issue)
    monitor.check(issue)
    issue.reload
  end

  def router
    PollRouter.new(config: CONFIG, project_config: PROJECT_CONFIG,
                   logger: @logger, token: 'tok', pool: nil)
  end

  def monitor
    PipelineMonitor.allocate.tap do |instance|
      instance.send(:init_runner, client: @client, config: CONFIG, project_config: PROJECT_CONFIG,
                                  logger: @logger, token: 'tok')
      # The one step this test does not run: `mr-review` is an external binary.
      # What it records is the only thing the test needs from it — that the
      # routing reached the review at all, and the state the row was in when it
      # did.
      instance.define_singleton_method(:execute_mr_review) do |reviewed|
        @reviews_recorder << reviewed.status
        false
      end
      instance.instance_variable_set(:@reviews_recorder, @reviews)
    end
  end

  # Every `labels:` payload the run sent to GitLab, split back into the label
  # list `manage_labels` joined.
  def labels_sent
    @client.edits.filter_map { |(_, attrs)| attrs[:labels]&.split(',') }.flatten
  end

  # --- a request nobody has ever reviewed -----------------------------------

  def test_a_never_reviewed_request_is_not_announced_as_ready_for_review
    issue = poll(reenter(review_count: 0))

    refute_includes labels_sent, PROJECT_CONFIG['label_done'],
                    'a request no reviewer ever looked at was posed on the feature-review column'
    refute_equal 'done', issue.status,
                 'a request no reviewer ever looked at was finished on its first green pipeline'
  end

  def test_a_never_reviewed_request_is_reviewed
    poll(reenter(review_count: 0))

    assert_equal ['reviewing'], @reviews,
                 'the green pipeline after a reentry skipped the review of a never-reviewed request'
  end

  # --- the nominal reentry, which must not change ---------------------------
  #
  # Without these, the fix could be read as "never trust the counter" and the
  # delivered request a human reposed a label on would be reviewed a second time
  # on every reentry.

  def test_a_reviewed_request_still_finishes_on_a_clean_green_pipeline
    issue = poll(reenter(review_count: 1))

    assert_equal 'done', issue.status
    assert_includes labels_sent, PROJECT_CONFIG['label_done']
    assert_empty @reviews, 'a request that had already been reviewed was reviewed again'
  end

  def test_a_reviewed_request_with_open_threads_goes_back_to_fixing_them
    issue = poll(reenter(review_count: 1, unresolved_discussions: 2))

    assert_equal 'fixing_discussions', issue.status
    refute_includes labels_sent, PROJECT_CONFIG['label_done']
  end

  # The activity keys the run wrote, in order. Read off the `activity_events`
  # rows rather than off the rendered French, because the key is what the
  # decision *is*: `ActivityLogger.payload_for` stores it beside the rendered
  # line, and both sinks (the GitLab note and this row) come from that one key.
  def activity_keys
    ActivityEvent.where(kind: 'danger_claude').order(:id).filter_map { |event| event.payload['key'] }
  end

  # --- the line the reentry writes about itself -----------------------------
  #
  # The other four tests here observe the *routing*: they let the next poll run
  # and check where the row went. Nothing observed what the reentry **said**,
  # and putting the pre-#85 line back (`:reenter_to_fix` in every case, "will
  # route to fixing_discussions") left the whole suite green. A request at 0 is
  # announced as going to have its review threads checked, on a request that has
  # no threads because no review ever opened one — the same false statement as
  # the `review_count: 1` write, one layer up, and the one Autodev #85 assertion
  # nothing held.

  def test_a_never_reviewed_reentry_announces_the_review
    reenter(review_count: 0)

    assert_includes activity_keys, 'reenter_to_review',
                    'the reentry of a never-reviewed request did not announce the review'
    refute_includes activity_keys, 'reenter_to_fix',
                    'the reentry announced discussions to fix on a request that has none'
  end

  def test_a_reviewed_reentry_still_announces_the_discussion_check
    reenter(review_count: 1)

    assert_includes activity_keys, 'reenter_to_fix'
    refute_includes activity_keys, 'reenter_to_review'
  end

  # Both sinks of the same decision: the activity key above and this line. They
  # are chosen once, on the same term, so they cannot disagree — which is the
  # property, not the wording.
  def test_the_log_line_names_the_branch_the_reentry_took
    { 0 => 'the review', 1 => 'fixing_discussions' }.each do |count, expected|
      setup
      reenter(review_count: count)

      assert(@logger.lines.any? { |l| l.include?('checking_pipeline') && l.include?(expected) },
             "at review_count #{count} no log line named #{expected}: #{@logger.lines.inspect}")
    end
  end
end
