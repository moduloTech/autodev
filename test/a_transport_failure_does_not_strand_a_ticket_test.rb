# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'
require 'autodev/issue_processor'

# A transport failure inside a GitLab *write* helper must not strand a ticket on
# the bot (Autodev #126, measured on A#134 / powerpanne#16354).
#
# The shape: `checking_pipeline → done (pipeline_green)` fired, then
# `finalize_green_done` called `apply_label_done` → `manage_labels` →
# `@client.issue`, which raised `Net::OpenTimeout`. `manage_labels`,
# `hand_ticket_back` and `notify_issue` rescued `Gitlab::Error::ResponseError`
# only, and a TCP timeout is a `Timeout::Error`: the exception escaped to
# `PipelineMonitor#check`, which only logs. The row stayed `done`, unflagged,
# with the ticket on the bot — and nothing after the transition ever ran again,
# since no pass selects a `done` row.
#
# The three helpers already carried the contract "a failed write is logged and
# the caller carries on" for an HTTP error; a TCP timeout is the same outage in
# another class. These tests drive the real LabelManager / IssueNotifier code:
# `hand_ticket_back` is never stubbed, because the handback being skipped is the
# defect.
class ATransportFailureDoesNotStrandATicketTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review',
                     'label_attention' => 'Development::StandBy' }.freeze
  AUTHOR_ID = 42
  MR_IID = 7
  MR_URL = 'http://gitlab/mr/7'

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # One instance per member of `GitlabHelpers::TRANSPORT_ERRORS`, keyed by the
  # member, so a seventh class added to the constant fails
  # `test_every_transport_class_is_exercised` instead of going untested.
  TRANSPORT_SAMPLES = {
    Gitlab::Error::ResponseError => lambda {
      Gitlab::Error::ResponseError.new(
        FakeResponse.new('boom', 502, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
      )
    },
    SystemCallError => -> { Errno::ECONNRESET.new('Connection reset by peer') },
    Timeout::Error => -> { Net::OpenTimeout.new('execution expired') },
    SocketError => -> { SocketError.new('getaddrinfo: nodename nor servname provided') },
    OpenSSL::SSL::SSLError => -> { OpenSSL::SSL::SSLError.new('SSL_connect returned=1') },
    EOFError => -> { EOFError.new('end of file reached') }
  }.freeze

  # Records every GitLab call and raises on the one each test names. `edits` are
  # the edits GitLab accepted; `attempted` includes the ones it refused, so a
  # test can tell "never tried" from "tried and failed".
  class FakeClient
    GlIssue = Struct.new(:labels, :id)
    GlMr = Struct.new(:state, :head_pipeline)
    Pipeline = Struct.new(:id, :status)
    Note = Struct.new(:id, :body)

    # `merge_request_discussions` answers a paginated response.
    class Paginated
      def initialize(items) = @items = items
      def auto_paginate = @items
    end

    attr_reader :edits, :attempted, :notes, :calls

    def initialize(raise_on: {})
      @raise_on = raise_on
      @edits = []
      @attempted = []
      @notes = []
      @calls = []
    end

    def user = GlIssue.new([], 999)

    def issue(_path, _iid)
      @calls << :issue
      maybe_raise(:issue)
      GlIssue.new(['To do', 'Development::Doing'], 1)
    end

    def merge_request(_path, _iid) = GlMr.new('opened', Pipeline.new(1, 'success'))
    def merge_request_discussions(_path, _iid, **) = Paginated.new([])

    def edit_issue(_path, iid, **attrs)
      @attempted << [iid, attrs]
      maybe_raise(attrs.key?(:assignee_ids) ? :assignee_edit : :labels_edit)
      @edits << [iid, attrs]
      return GlIssue.new([], 1) unless attrs.key?(:assignee_ids)

      # An assignment GitLab honoured: `hand_ticket_back` reads it back.
      Gitlab::ObjectifiedHash.new('iid' => iid, 'assignees' => attrs[:assignee_ids].map { |id| { 'id' => id } })
    end

    def create_issue_note(_path, _iid, body)
      @calls << :note
      maybe_raise(:note)
      @notes << body
      Note.new(@notes.size, body)
    end

    # By id: the activity note is edited in place while other notes land after it.
    def issue_note(_path, _iid, note_id) = Note.new(note_id, @notes[note_id - 1].to_s)

    def edit_issue_note(_path, _iid, note_id, body)
      @notes[note_id - 1] = body
      Note.new(note_id, body)
    end

    private

    def maybe_raise(call)
      error = @raise_on[call]
      raise error.is_a?(Proc) ? error.call : error if error
    end
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, 999)
    @logger = StubLogger.new
  end

  def worker(klass, client)
    @client = client
    klass.allocate.tap do |instance|
      instance.send(:init_runner, client: client, config: {}, project_config: PROJECT_CONFIG,
                                  logger: @logger, token: 'tok')
    end
  end

  # `finished_at` as `mr_created` left it on A#134 — the stamp the done path
  # must move.
  def watched(**overrides)
    issue = create_issue(mr_iid: MR_IID, mr_url: MR_URL, issue_author_id: AUTHOR_ID, locale: 'fr',
                         review_count: 1, finished_at: 4.hours.ago, **overrides)
    advance_to(issue, 'checking_pipeline')
    issue.update_columns(finished_at: 4.hours.ago)
    issue
  end

  def activity_keys(issue)
    ActivityEvent.where(issue_id: issue.id, kind: 'danger_claude')
                 .map { |e| JSON.parse(e.payload_json)['key'] }
  end

  def rendered(key, **vars)
    Locales.t(key, locale: :fr, tag: "**autodev** (v#{Autodev::VERSION})", **vars)
  end

  def reassigned_sentence = Locales.t(:abandon_reassigned, locale: :fr)
  def check_failed_lines = @logger.messages.grep(/Pipeline check failed/)
  def timeout = -> { Net::OpenTimeout.new('execution expired') }

  def assert_handed_to(target_id)
    assert_includes @client.edits.map(&:last), { assignee_ids: [target_id] },
                    "no { assignee_ids: [#{target_id}] } edit in #{@client.edits.inspect}"
  end

  # The row reached its end and the sequence after the transition ran to its
  # last write: `finished_at` is the stamp every terminal path moves.
  def assert_finished(issue, status: 'done')
    assert_equal status, issue.status
    assert_operator issue.finished_at, :>, 1.minute.ago, 'finished_at was never moved'
  end

  # --- the A#134 shape, through `PipelineMonitor#check` ------------------

  def green_done(raise_on)
    issue = watched
    worker(PipelineMonitor, FakeClient.new(raise_on: raise_on)).check(issue)
    issue.reload
  end

  def assert_delivered(issue)
    assert_finished(issue)
    assert_handed_to(AUTHOR_ID)
    assert_includes @client.notes, rendered(:done_nominal, label_todo: 'To do')
    assert_includes activity_keys(issue), 'pipeline_green_done'
    assert_empty check_failed_lines
  end

  def test_a_label_read_that_times_out_still_hands_the_ticket_back
    assert_delivered(green_done(issue: timeout))
  end

  def test_a_label_write_whose_connection_resets_still_hands_the_ticket_back
    assert_delivered(green_done(labels_edit: -> { Errno::ECONNRESET.new('Connection reset by peer') }))
  end

  # `notify_issue` still raises a transport failure (see
  # `a_note_posted_before_a_transition_still_aborts_test.rb` for why), and here
  # that costs nothing that matters: the handback and `finished_at` are written
  # before the delivery note, so the escaping error only loses the activity line.
  def test_a_delivery_note_whose_connection_resets_has_already_handed_the_ticket_back
    issue = green_done(note: -> { Errno::ECONNRESET.new('Connection reset by peer') })

    assert_finished(issue)
    assert_handed_to(AUTHOR_ID)
    refute_empty check_failed_lines, 'the note failure should still reach the poll boundary'
  end

  # --- the same shape through the three other post-transition sequences ----

  def test_an_abandon_whose_label_read_times_out_still_hands_the_ticket_back
    issue = watched
    worker(PipelineMonitor, FakeClient.new(raise_on: { issue: timeout }))
      .send(:abandon_issue, issue, :stagnation_pipeline, detail: 'deploy')

    assert_finished(issue.reload)
    assert_handed_to(AUTHOR_ID)
    assert(@client.notes.any? { |n| n.include?(reassigned_sentence) })
  end

  def answering_question
    issue = create_issue(issue_author_id: AUTHOR_ID, locale: 'fr')
    advance_to(issue, 'checking_spec')
    issue.question_detected!
    issue.update_columns(finished_at: 4.hours.ago)
    issue
  end

  def test_a_question_whose_label_read_times_out_still_hands_the_ticket_back
    issue = answering_question
    worker(IssueProcessor, FakeClient.new(raise_on: { issue: timeout }))
      .send(:finalize_question, issue.issue_iid, issue)

    assert_finished(issue.reload)
    assert_handed_to(AUTHOR_ID)
    assert_includes @client.notes, rendered(:done_question, label_todo: 'To do')
  end

  def test_a_review_give_up_whose_label_read_times_out_still_hands_the_ticket_back
    issue = watched
    issue.update_columns(status: 'reviewing')
    worker(PipelineMonitor, FakeClient.new(raise_on: { issue: timeout })).send(:give_up_reviewing, issue.reload)

    assert_finished(issue.reload)
    assert_handed_to(AUTHOR_ID)
    assert_equal 'review_failures_exhausted', issue.attention_reason
  end

  # --- `manage_labels` across the whole transport family -----------------

  def test_every_transport_class_is_exercised
    assert_equal GitlabHelpers::TRANSPORT_ERRORS.sort_by(&:name), TRANSPORT_SAMPLES.keys.sort_by(&:name)
  end

  def test_manage_labels_answers_nothing_removed_for_every_transport_failure
    TRANSPORT_SAMPLES.each do |klass, sample|
      host = worker(PipelineMonitor, FakeClient.new(raise_on: { issue: sample }))

      assert_equal [], host.send(:manage_labels, 1, remove: ['Development::Doing'], add: 'Done'),
                   "#{klass} escaped manage_labels or answered something other than []"
    end
  end

  # The guard against widening to `rescue StandardError`: a bug in the caller's
  # client is not an outage, and swallowing it would hide it for good.
  def test_a_programming_error_in_manage_labels_still_raises
    host = worker(PipelineMonitor, FakeClient.new(raise_on: { issue: -> { NoMethodError.new('labels') } }))

    assert_raises(NoMethodError) { host.send(:manage_labels, 1, remove: [], add: 'Done') }
  end

  # --- a handback that times out is not claimed ---------------------------

  def read_timeout = -> { Net::ReadTimeout.new('read') }

  def test_a_handback_that_times_out_answers_false
    host = worker(PipelineMonitor, FakeClient.new(raise_on: { assignee_edit: read_timeout }))

    assert_same false, host.send(:hand_ticket_back, watched)
  end

  # --- a handback is claimed only when GitLab honoured it (alpha-56 lot) --

  # GitLab Community answers 200 to an assignment it did not apply (Autodev
  # #126), so the answer is read back like `ExternalState#hand_over_to` and
  # `CloseHandback` read it. `edit_issue` answers the payload given here.
  class AnsweringClient < FakeClient
    def initialize(assignees) = super().tap { @assignees = assignees }

    def edit_issue(path, iid, **attrs)
      super
      Gitlab::ObjectifiedHash.new('iid' => iid, 'assignees' => @assignees.map { |id| { 'id' => id } })
    end
  end

  def test_a_handback_gitlab_answered_without_the_target_answers_false
    host = worker(PipelineMonitor, AnsweringClient.new([999]))

    assert_same false, host.send(:hand_ticket_back, watched)
    assert_includes @client.edits.map(&:last), { assignee_ids: [AUTHOR_ID] }, 'precondition: the edit was sent'
  end

  def test_a_handback_gitlab_answered_with_the_target_answers_true
    host = worker(PipelineMonitor, AnsweringClient.new([AUTHOR_ID]))

    assert_same true, host.send(:hand_ticket_back, watched)
  end

  def test_an_abandon_whose_handback_gitlab_did_not_honour_does_not_claim_one
    issue = watched
    worker(PipelineMonitor, AnsweringClient.new([999]))
      .send(:abandon_issue, issue, :stagnation_pipeline, detail: 'deploy')
    reason_note = @client.notes.find { |n| n.include?('deploy') }

    assert reason_note, 'the abandon note was not posted'
    refute_includes reason_note, reassigned_sentence
  end

  def abandon_with_timed_out_handback
    issue = watched
    worker(PipelineMonitor, FakeClient.new(raise_on: { assignee_edit: read_timeout }))
      .send(:abandon_issue, issue, :stagnation_pipeline, detail: 'deploy')
    issue.reload
  end

  def test_an_abandon_whose_handback_times_out_still_flags_the_row
    issue = abandon_with_timed_out_handback

    assert_equal ['done', true], [issue.status, issue.needs_attention]
    assert_includes @client.attempted.map(&:last), { assignee_ids: [AUTHOR_ID] }
  end

  def test_an_abandon_whose_handback_times_out_does_not_claim_one
    abandon_with_timed_out_handback
    reason_note = @client.notes.find { |n| n.include?('deploy') }

    assert reason_note, 'the abandon note was not posted'
    refute_includes reason_note, reassigned_sentence
  end

  def test_a_note_that_times_out_still_raises
    host = worker(PipelineMonitor, FakeClient.new(raise_on: { note: -> { Net::ReadTimeout.new('read') } }))

    assert_raises(Net::ReadTimeout) { host.send(:notify_issue, 1, 'hello') }
  end
end
