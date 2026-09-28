# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# A label handover hands the ticket to the person who moved the label
# (Autodev #126, owner's decision of 28/09/2026).
#
# `ExternalState#stop_on_handover` is reached only while the bot is still the
# assignee (`not_ours?` asks that first), and it used to close the row and leave
# the ticket there: A#130 and A#132 (powerpanne#16258, #16237) sat on the bot's
# list — nobody's list — after a human moved them to `Development::Awaiting CR`.
# The label event that decided the verdict already names that human, so the
# verdict carries them (`actor_id`) and the ticket goes to them, else to
# `Issue#handback_target`. The handback runs before the stop notice so the notice
# can say it happened, and only then.
class ALabelHandoverHandsTheTicketBackTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To Do'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example', 'poll_interval' => 300 }.freeze
  AUTODEV_ID = 7
  MOVER_ID = 999
  AUTHOR_ID = 42
  DISPLACED_ID = 55
  DOING = 'Development::Doing'
  AWAITING_CR = 'Development::Awaiting CR'

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)
  FakeLabel = Struct.new(:name)
  FakeEvent = Struct.new(:action, :label, :user)
  FakeNote = Struct.new(:id, :body)

  # One ordered log of every write, so "the handback precedes the notice" is a
  # fact read off the log rather than an inference.
  class RecordingClient
    attr_reader :log, :notes

    def initialize(labels: [AWAITING_CR], events: [], edit_error: nil)
      @labels = labels
      @events = events
      @edit_error = edit_error
      @log = []
      @notes = []
    end

    def user = FakeUser.new(AUTODEV_ID)
    def issue(_path, _iid) = FakeIssue.new('opened', [FakeAssignee.new(AUTODEV_ID)], @labels)
    def issue_label_events(_path, _iid) = Gitlab::PaginatedResponse.new(@events)

    def edit_issue(_path, _iid, **attrs)
      @log << [:edit, attrs]
      raise @edit_error.call if @edit_error

      FakeIssue.new('opened', [], @labels)
    end

    def create_issue_note(_path, _iid, body)
      @log << [:note, body]
      @notes << body
      FakeNote.new(@notes.size, body)
    end

    def assignee_edits = @log.select { |kind, attrs| kind == :edit && attrs.key?(:assignee_ids) }.map(&:last)
  end

  class Host
    include Autodev::ExternalState

    def initialize(client, logger)
      @client = client
      @path = 'group/project'
      @project_config = PROJECT_CONFIG
      @logger = logger
    end
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
    @logger = StubLogger.new
  end

  def moved_by(actor_id)
    [FakeEvent.new('add', FakeLabel.new(DOING), FakeUser.new(AUTODEV_ID)),
     FakeEvent.new('remove', FakeLabel.new(DOING), FakeUser.new(actor_id)),
     FakeEvent.new('add', FakeLabel.new(AWAITING_CR), FakeUser.new(actor_id))]
  end

  def gl_moved = FakeIssue.new('opened', [FakeAssignee.new(AUTODEV_ID)], [AWAITING_CR])

  def active(**overrides)
    create_issue({ status: 'checking_pipeline', mr_iid: 3, issue_author_id: AUTHOR_ID,
                   locale: 'fr' }.merge(overrides))
  end

  def stop_notice_base
    Locales.t(:handover_workflow_moved, locale: :fr, tag: ActivityLogger.tag, label_todo: 'To Do',
                                        label: AWAITING_CR)
  end

  def stop_notices(client) = client.notes.select { |n| n.start_with?(stop_notice_base) }
  def reassigned_sentence = Locales.t(:abandon_reassigned, locale: :fr)

  # --- A2: the verdict names who moved the ticket -------------------------

  def verdict_for(labels, events, config = PROJECT_CONFIG)
    Autodev::LabelHandover.new(client: RecordingClient.new(events: events), path: 'group/project',
                               project_config: config, logger: @logger)
                          .verdict(FakeIssue.new('opened', [], labels), 1)
  end

  # Two humans on one ticket: the one whose edit produced the label we read is
  # the one who took the work on, not the first one to touch it.
  def test_a_workflow_move_names_the_human_who_posed_the_new_label
    events = [FakeEvent.new('remove', FakeLabel.new(DOING), FakeUser.new(501)),
              FakeEvent.new('add', FakeLabel.new(AWAITING_CR), FakeUser.new(502))]

    assert_equal 502, verdict_for([AWAITING_CR], events).actor_id
  end

  def test_a_removed_doing_label_names_the_human_who_removed_it
    events = [FakeEvent.new('add', FakeLabel.new(DOING), FakeUser.new(AUTODEV_ID)),
              FakeEvent.new('remove', FakeLabel.new(DOING), FakeUser.new(501)),
              FakeEvent.new('add', FakeLabel.new('PM::Evolution'), FakeUser.new(502))]
    verdict = verdict_for(['PM::Evolution'], events)

    assert_equal :doing_removed, verdict.reason
    assert_equal 501, verdict.actor_id
  end

  def test_a_done_label_names_the_human_who_added_it
    done = PROJECT_CONFIG['label_done']
    events = [FakeEvent.new('remove', FakeLabel.new(DOING), FakeUser.new(501)),
              FakeEvent.new('add', FakeLabel.new(done), FakeUser.new(503))]
    verdict = verdict_for([done], events)

    assert_equal :done_added, verdict.reason
    assert_equal 503, verdict.actor_id
  end

  # --- A3: the three paths that reach `stop_on_handover` ------------------

  def test_the_handover_hands_the_ticket_to_the_mover
    client = RecordingClient.new(events: moved_by(MOVER_ID))
    Host.new(client, @logger).stop_on_handover(active, gl_moved)

    assert_equal [{ assignee_ids: [MOVER_ID] }], client.assignee_edits
  end

  def test_the_active_sweep_hands_the_ticket_to_the_mover
    client = RecordingClient.new(events: moved_by(MOVER_ID))
    issue = active
    dispatcher(client).send(:dispatch_unassignment)

    assert_equal 'closed', issue.reload.status
    assert_equal [{ assignee_ids: [MOVER_ID] }], client.assignee_edits
  end

  def test_the_dormant_audit_hands_the_ticket_to_the_mover
    client = RecordingClient.new(events: moved_by(MOVER_ID))
    issue = create_issue(status: 'pending', next_retry_at: nil, created_at: 2.hours.ago,
                         issue_author_id: AUTHOR_ID, locale: 'fr')
    Autodev::DormantAudit.new(client: client, path: 'group/project', config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger).run

    assert_equal 'closed', issue.reload.status
    assert_equal [{ assignee_ids: [MOVER_ID] }], client.assignee_edits
  end

  def dispatcher(client)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, 'group/project')
      d.instance_variable_set(:@project_config, PROJECT_CONFIG.merge('path' => 'group/project'))
      d.instance_variable_set(:@config, CONFIG)
      d.instance_variable_set(:@logger, @logger)
      d.instance_variable_set(:@client, client)
    end
  end

  # --- the order, and what the notice may claim ---------------------------

  # The writes that matter here, in the order they reached GitLab.
  def write_order(client)
    client.log.filter_map do |kind, payload|
      next :handback if kind == :edit && payload.key?(:assignee_ids)

      :notice if kind == :note && payload.start_with?(stop_notice_base)
    end
  end

  def test_the_handback_precedes_the_stop_notice
    client = RecordingClient.new(events: moved_by(MOVER_ID))
    Host.new(client, @logger).stop_on_handover(active, gl_moved)

    assert_equal %i[handback notice], write_order(client)
  end

  def test_the_stop_notice_says_the_ticket_changed_hands
    client = RecordingClient.new(events: moved_by(MOVER_ID))
    Host.new(client, @logger).stop_on_handover(active, gl_moved)

    assert_equal ["#{stop_notice_base}\n\n#{reassigned_sentence}"], stop_notices(client)
  end

  def stop_with_timed_out_handback(issue)
    client = RecordingClient.new(events: moved_by(MOVER_ID), edit_error: -> { Net::ReadTimeout.new('read') })
    [client, Host.new(client, @logger).stop_on_handover(issue, gl_moved)]
  end

  def test_a_handback_that_times_out_still_closes_the_row_without_claiming_one
    issue = active
    client, verdict = stop_with_timed_out_handback(issue)

    assert_equal ['closed', MOVER_ID], [issue.reload.status, verdict&.actor_id]
    assert_equal [stop_notice_base], stop_notices(client)
  end

  def test_a_handback_that_times_out_is_logged
    issue = active
    stop_with_timed_out_handback(issue)

    assert(@logger.messages.any? { |m| m.include?("Failed to hand ##{issue.issue_iid} over") })
  end

  # --- the fallback when the verdict names nobody -------------------------

  def host_with_verdict(client, verdict)
    Host.new(client, @logger).tap do |host|
      handover = Object.new
      handover.define_singleton_method(:verdict) { |*| verdict }
      host.define_singleton_method(:label_handover) { handover }
    end
  end

  def anonymous_verdict = Autodev::LabelHandover::Verdict.new(:workflow_moved, AWAITING_CR, nil)

  def test_without_an_actor_the_ticket_goes_to_the_displaced_assignee
    client = RecordingClient.new
    host_with_verdict(client, anonymous_verdict).stop_on_handover(active(displaced_assignee_id: DISPLACED_ID),
                                                                  gl_moved)

    assert_equal [{ assignee_ids: [DISPLACED_ID] }], client.assignee_edits
  end

  def test_without_an_actor_nor_a_target_nothing_is_edited_nor_claimed
    client = RecordingClient.new
    issue = active(issue_author_id: nil)
    host_with_verdict(client, anonymous_verdict).stop_on_handover(issue, gl_moved)

    assert_equal 'closed', issue.reload.status
    assert_empty client.assignee_edits
    assert_equal [stop_notice_base], stop_notices(client)
  end

  # --- no verdict, or no row to close: no handback ------------------------

  def test_autodevs_own_move_hands_nothing_back
    client = RecordingClient.new(events: moved_by(AUTODEV_ID))
    issue = active

    assert_nil Host.new(client, @logger).stop_on_handover(issue, gl_moved)
    assert_equal 'checking_pipeline', issue.reload.status
    assert_empty client.assignee_edits
  end

  def test_a_row_already_closed_hands_nothing_back
    client = RecordingClient.new(events: moved_by(MOVER_ID))
    Host.new(client, @logger).stop_on_handover(active(status: 'closed'), gl_moved)

    assert_empty client.assignee_edits
  end
end
