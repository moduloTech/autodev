# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'

# Autodev #95, fourth file — the one the neutral review of the fix added.
#
# `a_refused_position_falls_back_to_a_comment_test.rb` pins the fallback: a
# position GitLab refuses does not lose the finding, it moves it into the summary
# comment. What that file could not see, because it stops at `ReviewPublisher`, is
# what the *line* then does with a review whose findings all ended up as prose.
#
# It delivered it. `publish` answered a Hash, `publish_from_contract` read that as
# `true`, `finalize_review_success` moved `review_count` to 1, and the next poll
# asked GitLab for the unresolved threads of a merge request that carries none —
# a summary comment is a note, not a resolvable discussion — so `no_discussions`
# was true and the request ended `done`, unflagged, under `label_done`
# (`Development::Awaiting Feature Review` on the project this was measured on).
# A merge request in conflict, with a `changes_requested` verdict and findings of
# severity `error`, announced as ready for feature review.
#
# The cause is more general than the conflict that revealed it: **`contract.verdict`
# was read nowhere**. The verdict held the delivery only by accident, through the
# discussion threads the findings happened to be anchored on, so the moment they
# could not be anchored nothing held it at all — and a review that requests
# changes with every finding summary-only (legal in the contract: a blocking
# finding with no line, an `info`) had the same hole with no 400 in sight.
#
# So the verdict now holds the delivery itself. A `changes_requested` review that
# left no unresolved thread on the merge request cannot conclude the request: the
# line stops under `review_findings_unanchored`, which is the shape of Autodev
# #63, #81, #85 and #91 — `label_attention`, never `label_done`, the ticket handed
# back to the only person who can resolve the conflict, and a comment saying
# exactly what happened.
# rubocop:disable Metrics/ClassLength -- most of these lines are the one GitLab
# stub that lets a real `check` run all the way through `ReviewPublisher`, which
# is what makes the chain under test the real one rather than a rehearsal of it.
class ADemotedReviewIsNotADeliveryTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'

  FakeMr = Struct.new(:iid, :state, :target_branch, :head_pipeline, :diff_refs)
  FakePipeline = Struct.new(:id, :status)
  FakeRefs = Struct.new(:base_sha, :start_sha, :head_sha)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # A merge request in conflict: its diff carries no resolvable line codes, so
  # every position handed to `create_merge_request_discussion` comes back 400.
  # `anchor:` false is that merge request; true is the healthy control.
  class StubClient
    Note = Struct.new(:id, :body, :position)
    Discussion = Struct.new(:notes)
    GlIssue = Struct.new(:labels, :id)

    attr_reader :notes, :edits, :discussions

    def initialize(anchor:)
      @anchor = anchor
      @notes = []
      @edits = []
      @discussions = []
    end

    def merge_request(_path, iid)
      ADemotedReviewIsNotADeliveryTest::FakeMr.new(
        iid, 'opened', 'master',
        ADemotedReviewIsNotADeliveryTest::FakePipeline.new(9, 'success'),
        ADemotedReviewIsNotADeliveryTest::FakeRefs.new('b', 's', 'h')
      )
    end

    def create_merge_request_discussion(_path, _iid, opts)
      raise ADemotedReviewIsNotADeliveryTest.refusal unless @anchor

      @discussions << opts
      Discussion.new([Note.new(1, opts[:body], opts[:position])])
    end

    def create_merge_request_note(_path, _iid, body)
      @notes << body
      Note.new(@notes.size, body, nil)
    end

    def merge_request_notes(_path, _iid, **_opts)
      FakePaginated.new(@notes.map { |b| Note.new(1, b, nil) })
    end

    # The summary comment is a note, not a resolvable thread — which is the whole
    # reason the delivery gate could not see the demoted findings.
    def merge_request_discussions(_path, _iid, **_opts) = FakePaginated.new([])
    def issue(_path, _iid) = GlIssue.new(labels: ['Doing'], id: 1)
    def issue_notes(_path, _iid, **_opts) = FakePaginated.new([])
    def issue_links(_path, _iid) = []
    def user = GlIssue.new(labels: [], id: 999)

    def edit_issue(_path, iid, **attrs)
      @edits << [iid, attrs]
      GlIssue.new(labels: [], id: 1)
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      Note.new(@notes.size, body, nil)
    end

    def issue_note(_path, _iid, note_id) = Note.new(note_id, @notes.last.to_s, nil)

    def edit_issue_note(_path, _iid, _note_id, body)
      @notes[-1] = body
      Note.new(1, body, nil)
    end
  end

  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
    def each(&) = @items.each(&)
  end

  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*, **| nil } }
  end

  def self.refusal
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('400 Bad request - Note {:line_code=>["must be a valid line code"]}',
                       400, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  def setup = setup_database

  # --- the measured chain --------------------------------------------------

  # The one that decides. Two polls is what the production line took: the first
  # published, the second delivered.
  def test_a_changes_requested_review_that_anchored_nothing_does_not_deliver
    row = watched_issue
    2.times { poll(row, anchor: false) }

    assert row.reload.needs_attention, 'delivered as reviewed with every finding unaddressed'
    assert_equal %w[done review_findings_unanchored], [row.status, row.attention_reason]
  end

  # `label_done` reads "ready for feature review" on the projects concerned, which
  # is the sentence Autodev #63 was filed against. The end label of a give-up is
  # `label_attention`, and it is posed by the shared abandon point.
  def test_the_end_label_is_never_posed_on_it
    row = watched_issue
    2.times { poll(row, anchor: false) }

    assert_empty labels[:done], 'label_done was posed on a merge request nothing reviewed'
    refute_empty labels[:attention]
  end

  # The findings are not lost by the give-up either: the summary comment carrying
  # them is posted before the line stops.
  def test_the_findings_are_still_published_before_the_line_stops
    row = watched_issue
    client = poll(row, anchor: false)

    assert_includes client.notes.join("\n"), 'the finding body'
  end

  # The ticket goes back to the only person who can resolve the conflict.
  def test_the_ticket_is_handed_back_to_its_author
    row = watched_issue
    client = poll(row, anchor: false)

    assert_includes client.edits.map { |(_iid, attrs)| attrs[:assignee_ids] }, [42]
  end

  # Not a review failure, and this is the Autodev #85 line: the review ran and
  # judged. Blaming it would put the wrong sentence on a client's ticket.
  def test_the_review_failure_budget_is_not_spent
    row = watched_issue
    poll(row, anchor: false)

    assert_equal 0, row.reload.review_failure_count.to_i
  end

  # --- the controls --------------------------------------------------------

  # One anchored finding is enough: the merge request now carries an unresolved
  # thread, the delivery gate reads it, and the request takes its normal course.
  def test_an_anchored_review_still_takes_its_normal_course
    row = watched_issue
    poll(row, anchor: true)

    assert_equal 'checking_pipeline', row.reload.status
    assert_equal 1, row.review_count
    refute row.needs_attention
  end

  # The verdict is what holds the delivery, not the anchoring. A review that
  # approves has nothing for anybody to address, so findings it could not anchor
  # do not stop it — they are advice, in the summary comment, on an approved
  # merge request.
  def test_an_approving_review_delivers_even_when_nothing_could_be_anchored
    row = watched_issue
    poll(row, anchor: false, verdict: 'approve')

    assert_equal 'checking_pipeline', row.reload.status
    assert_equal 1, row.review_count
    refute row.needs_attention
  end

  # The one case where "this publication anchored nothing" must not be read as
  # "nothing anchors this verdict": a previous cycle already published the review
  # — its marker is on the merge request — and died before the counter moved. What
  # it anchored then is on the merge request, unresolved, and the delivery gate is
  # the right reader of it. `publish` says so rather than being inferred from a
  # pair of zeroes it shares with the real case.
  def test_a_review_already_published_by_an_earlier_cycle_is_not_given_up_on
    row = watched_issue
    client = StubClient.new(anchor: false)
    client.create_merge_request_note(nil, nil, "already here #{ReviewPublisher::MARKER}")
    poll(row, anchor: false, client: client)

    assert_equal 'checking_pipeline', row.reload.status
    assert_equal 1, row.review_count
    refute row.needs_attention
  end

  private

  def watched_issue
    issue = Issue.create!(project_path: PROJECT_PATH, issue_iid: 15_205, mr_iid: 11_258,
                          mr_url: 'https://gitlab.example/mr/11258', issue_author_id: 42,
                          branch_name: 'autodev/issue-15205', status: 'checking_pipeline',
                          review_count: 0, locale: 'fr')
    issue.update(checking_pipeline_since: Time.current)
    issue
  end

  def contract_json(verdict)
    { verdict: verdict, summary: 'the summary',
      findings: [{ file: 'app/a.rb', line: 12, severity: 'error', body: 'the finding body' }] }.to_json
  end

  # Everything from `publish_from_contract` down is the real code: the clone and
  # the danger-claude call are what is stubbed, the contract is written where the
  # skill would have written it, and `ReviewPublisher` really talks to the client.
  def labels = @labels ||= { done: [], attention: [] }

  def poll(issue, anchor:, verdict: 'changes_requested', client: nil)
    client ||= StubClient.new(anchor: anchor)
    mon = worker(client, labels)
    body = contract_json(verdict)
    mon.define_singleton_method(:review_with_skill) do |row|
      path = send(:review_contract_path, row.mr_iid)
      File.write(path, body)
      send(:publish_from_contract, row, path)
    end
    mon.check(issue)
    client
  end

  def worker(client, labels)
    PipelineMonitor.allocate.tap do |obj|
      obj.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: { 'path' => PROJECT_PATH, 'review_skill' => 'mr-review' },
                             logger: NullLogger.new, token: 'tok')
      %i[log log_error].each { |m| obj.define_singleton_method(m) { |*| nil } }
      obj.define_singleton_method(:claude_available?) { true }
      obj.define_singleton_method(:apply_label_attention) { |iid| labels[:attention] << iid }
      obj.define_singleton_method(:apply_label_done) { |iid| labels[:done] << iid }
    end
  end
end
# rubocop:enable Metrics/ClassLength
