# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# The review runs once per merge request, and nothing counts rounds of it
# (Autodev #78).
#
# `PipelineMonitor#green_branch` used to send a green pipeline at
# `review_count >= MAX_REVIEW_ROUNDS` (3) to an abandon under
# `review_limit_reached`. `review_count` is written 0 → 1 once, by
# `finalize_review_success`, and capped at 1 by the reentry, so that branch was
# reachable only by tests that forced the count to 3 by hand — production held no
# row above 1 on 21/10/2026 and no row ever carried the reason. What bounds the
# correction loop is discussion stagnation, not a count of reviews.
#
# The owner deleted the branch, the constant and the reason. What these tests
# hold is the routing that is left: zero → the review, anything else → the
# post-review verdict on the unresolved threads, whatever the count says.
#
# Driven through `PipelineMonitor#check` on real rows, so a limit reintroduced
# anywhere on the green path — not only in `green_branch` — turns them red.
class AReviewRunsOncePerMergeRequestTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review',
                     'label_attention' => 'Development::StandBy' }.freeze
  CONFIG = { 'gitlab_token' => 'tok', 'gitlab_url' => 'https://gitlab.example' }.freeze

  # The value the deleted constant held: the count at which the old routing gave
  # a reviewed request up.
  OLD_LIMIT = 3

  # Records everything crossing the GitLab boundary so the real LabelManager /
  # IssueNotifier / ActivityLogger code runs against it.
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
    def issue(_path, _iid) = GlIssue.new(labels: ['Development::Doing'], id: 1)
    def user = GlIssue.new(labels: [], id: 999)
    def issue_notes(_path, _iid, **_opts) = Paginated.new([])

    def merge_request_discussions(_path, _iid, **_opts)
      threads = Array.new(@unresolved) do |i|
        Discussion.new(id: "d#{i}", notes: [DiscussionNote.new(resolvable: true, resolved: false, system: false,
                                                               created_at: '2026-10-01T10:00:00Z', body: 'finding')])
      end
      Paginated.new(threads)
    end

    def edit_issue(_path, iid, **attrs)
      @edits << [iid, attrs]
      return GlIssue.new(labels: [], id: 1) unless attrs.key?(:assignee_ids)

      Gitlab::ObjectifiedHash.new('iid' => iid, 'assignees' => attrs[:assignee_ids].map { |id| { 'id' => id } })
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
    @reviews = []
  end

  def watched(review_count:)
    issue = create_issue(mr_iid: 7, mr_url: 'http://gitlab/mr/7', issue_author_id: 42,
                         locale: 'fr', review_count: review_count)
    advance_to(issue, 'checking_pipeline')
    issue
  end

  # A green poll on the row. `launch_review` is replaced by a recorder: whether
  # the routing reached the review at all is the question, and the review itself
  # is an external tool.
  def poll(issue, unresolved_discussions: 0)
    @client = FakeClient.new(unresolved_discussions: unresolved_discussions)
    reviews = @reviews
    monitor = PipelineMonitor.allocate.tap do |instance|
      instance.send(:init_runner, client: @client, config: CONFIG, project_config: PROJECT_CONFIG,
                                  logger: NullLogger.new, token: 'tok')
      instance.define_singleton_method(:launch_review) { |reviewed| reviews << reviewed.review_count }
      instance.define_singleton_method(:claude_available?) { true }
    end
    monitor.check(issue)
    issue.reload
  end

  def transitions_for(issue)
    ActivityEvent.where(issue_id: issue.id, kind: 'transition')
                 .map { |e| JSON.parse(e.payload_json)['event'] }
  end

  def labels_sent
    @client.edits.filter_map { |(_, attrs)| attrs[:labels]&.split(',') }.flatten
  end

  # --- the count past the old limit is an ordinary reviewed request -----------

  def test_a_reviewed_request_with_no_open_thread_is_delivered_whatever_its_count
    issue = poll(watched(review_count: OLD_LIMIT))

    assert_equal ['done', false, nil], [issue.status, issue.needs_attention, issue.attention_reason]
    assert_includes labels_sent, PROJECT_CONFIG['label_done']
    refute_includes transitions_for(issue), 'abandon'
  end

  def test_a_reviewed_request_with_open_threads_goes_to_fixing_whatever_its_count
    issue = poll(watched(review_count: OLD_LIMIT), unresolved_discussions: 2)

    assert_equal ['fixing_discussions', false], [issue.status, issue.needs_attention]
  end

  # --- the review runs once ---------------------------------------------------

  def test_a_green_pipeline_on_an_unreviewed_request_reaches_the_review
    poll(watched(review_count: 0))

    assert_equal [0], @reviews
  end

  def test_a_green_pipeline_after_the_review_never_reviews_again
    [1, OLD_LIMIT].each { |count| poll(watched(review_count: count)) }

    assert_empty @reviews, 'a reviewed request was sent to a second review'
  end

  # --- the deleted vocabulary stays deleted -----------------------------------

  # The reverse guard in `test/i18n_derived_keys_test.rb` reads only the
  # watch-card explanation: the activity line and the bare notification key share
  # their namespaces with symbols that are not reasons, so no derived rule can
  # tell an orphan from a live key there. This pins the deletion of all three
  # sinks in both languages instead.
  def test_the_deleted_reason_has_no_copy_left
    left = %w[review_limit_reached activity_review_limit_reached
              web_errors_explain_attention_review_limit_reached].flat_map do |key|
      %i[fr en].filter_map { |language| "#{key} (#{language})" if Locales.merged_for(language).key?(key.to_sym) }
    end

    assert_empty left, 'the review-round limit is gone, its copy must go with it'
  end

  def test_no_review_round_constant_remains
    refute PipelineMonitor::Reviewer.const_defined?(:MAX_REVIEW_ROUNDS, false),
           'MAX_REVIEW_ROUNDS is back: the review runs once per merge request and nothing counts rounds'
  end
end
