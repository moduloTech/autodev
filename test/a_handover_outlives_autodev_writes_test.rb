# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/label_manager'
require 'active_support/testing/time_helpers'

# Autodev #101 — a handover is read off evidence autodev's own writes cannot
# erase.
#
# `LabelHandover#suspect` reads the current labels, and autodev rewrites them:
# `apply_label_doing` removes `other_workflow_labels(doing)`, `label_done`
# included. So a reviewer who poses `Development::Awaiting Feature Review` on a
# request in `fixing_discussions` has that label removed by the next round's
# `apply_label_doing`, and from then on nothing in the labels says anybody took
# the ticket. The resource label events still say it. They are read only when
# autodev has written labels since they were last read — the one way the
# evidence disappears — which is what keeps a healthy ticket at zero calls.
#
# Everything here runs the real `LabelManager` write against a client that
# records a GitLab event per label change, timestamped and attributed the way
# GitLab does it (`created_at` an ISO-8601 String, one event per label per edit),
# and the real `ExternalState#not_ours?` through `Autodev::HandoverStop`.
class AHandoverOutlivesAutodevWritesTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper
  include ActiveSupport::Testing::TimeHelpers

  AUTODEV_ID = 7
  HUMAN_ID = 999
  PATH = 'group/project'

  DOING = 'Development::Doing'
  DONE = 'Development::Awaiting Feature Review'
  MOVED_ON = 'Development::Awaiting CR'

  # powerpanne/core: the entry label is GitLab's unscoped `To Do`.
  POWERPANNE = { 'path' => PATH, 'labels_todo' => ['To Do'], 'label_doing' => DOING,
                 'label_done' => DONE, 'label_attention' => 'Development::StandBy' }.freeze

  # ff/fast/core: the entry label shares autodev's scope.
  FAST = { 'path' => PATH, 'labels_todo' => ['Development::ToDo'],
           'label_doing' => DOING, 'label_done' => 'Development::Done' }.freeze

  # A GitLab that keeps the one record `LabelHandover` trusts: every label change
  # is an event naming who made it and when. `edit_issue` is autodev's write,
  # `human_edit` a person's.
  class RecordingGitlab
    attr_reader :labels, :notes, :event_calls

    def initialize(labels)
      @labels = labels.dup
      @events = []
      @notes = []
      @event_calls = 0
      @on_events_read = nil
    end

    def user = Gitlab::ObjectifiedHash.new('id' => AUTODEV_ID)

    def issue(_path, iid)
      Gitlab::ObjectifiedHash.new('iid' => iid, 'labels' => @labels.dup, 'state' => 'opened',
                                  'assignees' => [{ 'id' => AUTODEV_ID }])
    end

    def edit_issue(_path, _iid, labels:)
      record(labels.split(','), AUTODEV_ID)
      nil
    end

    def human_edit(add: [], remove: [], actor: HUMAN_ID)
      record(@labels - remove + (add - @labels), actor)
    end

    # A test can hook the read, to move the clock while it is in flight.
    def on_events_read(&block) = (@on_events_read = block)

    def issue_label_events(_path, _iid)
      @event_calls += 1
      @on_events_read&.call
      Gitlab::PaginatedResponse.new(@events.map { |e| Gitlab::ObjectifiedHash.new(e) })
    end

    # A raw event, for the shapes a real edit through this double cannot make.
    def push_event(action, name, user_id, at)
      @events << { 'action' => action, 'label' => name && { 'name' => name },
                   'user' => user_id && { 'id' => user_id }, 'created_at' => at }
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      Gitlab::ObjectifiedHash.new('id' => @notes.size)
    end

    def issue_notes(*) = Gitlab::PaginatedResponse.new([])
    def edit_issue_note(*) = nil

    private

    def record(wanted, actor)
      at = Time.current.utc.iso8601(3)
      (@labels - wanted).each { |name| push_event('remove', name, actor, at) }
      (wanted - @labels).each { |name| push_event('add', name, actor, at) }
      @labels = wanted
    end
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def teardown
    travel_back
  end

  # --- the case this was written for ---------------------------------

  def test_a_done_label_a_human_posed_is_still_read_after_autodev_removed_it
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [DONE])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    refute_includes gitlab.labels, DONE, 'precondition: the write erased the current-state evidence'
    not_ours?(row, gitlab, POWERPANNE)

    assert_equal 'closed', row.reload.status
    assert_equal expected_note(:handover_done_added, DONE), gitlab.notes.first
  end

  def test_a_board_move_erased_by_autodev_names_where_the_ticket_went
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [MOVED_ON], remove: [DOING])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row, clear_scope: true)

    refute_includes gitlab.labels, MOVED_ON, 'precondition: the write erased the current-state evidence'
    verdict = handover(gitlab, POWERPANNE).verdict(gitlab.issue(PATH, row.issue_iid), row.issue_iid, row: row)

    assert_equal [:workflow_moved, MOVED_ON], [verdict.reason, verdict.label],
                 'the removal of Doing is the same edit; the move is the informative half'
  end

  def test_a_board_move_to_done_reads_as_done_even_after_autodev_reposed_doing
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [DONE], remove: [DOING])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_equal :done_added, scan(gitlab, row, POWERPANNE)&.reason,
                 "autodev's own add of Doing is not somebody asking for work again"
  end

  def test_a_removed_doing_label_autodev_reposed_is_read_as_doing_removed
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, remove: [DOING])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_equal :doing_removed, scan(gitlab, row, POWERPANNE)&.reason
  end

  def test_every_reason_the_scan_returns_has_a_locale_key
    %i[done_added workflow_moved doing_removed].each do |reason|
      assert_includes Autodev::LabelHandover::EXPECTED_ACTION.keys, reason
      assert_kind_of String, Locales.t(:"handover_#{reason}", locale: :fr, tag: 'x', label: 'y', label_todo: 'z')
    end
  end

  # --- what is not a handover ------------------------------------------

  def test_a_human_who_undoes_their_own_edit_has_not_handed_over
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [DONE])
    human!(gitlab, remove: [DONE])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_nil scan(gitlab, row, POWERPANNE)
  end

  def test_a_todo_reposed_after_the_move_is_a_request_for_work
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [DONE])
    human!(gitlab, add: ['To Do'])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_nil scan(gitlab, row, POWERPANNE)
  end

  def test_a_todo_autodev_posed_itself_does_not_neutralise_a_human_move
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [DONE])
    autodev!(gitlab, POWERPANNE, :apply_label_todo, row)

    assert_equal :done_added, scan(gitlab, row, POWERPANNE)&.reason,
                 'the clarification path posing the entry label is not a human asking again'
  end

  def test_the_fast_todo_gesture_in_one_edit_is_not_a_handover
    row, gitlab = claimed_row(FAST)
    human!(gitlab, add: ['Development::ToDo'], remove: [DOING])
    autodev!(gitlab, FAST, :apply_label_doing, row)

    assert_nil scan(gitlab, row, FAST)
  end

  def test_the_fast_todo_gesture_in_two_edits_is_not_a_handover_either
    row, gitlab = claimed_row(FAST)
    human!(gitlab, add: ['Development::ToDo'])
    travel 5.seconds
    gitlab.human_edit(remove: [DOING])
    autodev!(gitlab, FAST, :apply_label_doing, row)

    assert_nil scan(gitlab, row, FAST), "doing_dropped?'s rule: a todo label explains the absence, in any order"
  end

  def test_an_event_with_no_date_or_no_author_is_never_evidence
    row, gitlab = claimed_row(POWERPANNE)
    autodev!(gitlab, POWERPANNE, :apply_label_done, row)
    gitlab.push_event('add', MOVED_ON, HUMAN_ID, nil)
    gitlab.push_event('add', MOVED_ON, nil, Time.current.utc.iso8601(3))

    assert_nil scan(gitlab, row, POWERPANNE)
  end

  # --- the window --------------------------------------------------------

  # The window is `max(floor, started_at, created_at)`: each bound is pinned by
  # a row where it is the latest of the three, with one event on each side.
  def test_evidence_before_the_current_claim_is_ignored
    row, gitlab = windowed_row(started_at: 2.days.ago, label_events_seen_until: nil)
    human_done_at(gitlab, 3.days.ago)

    assert_nil scan(gitlab, row, POWERPANNE), 'an event before started_at belongs to an earlier claim'
  end

  def test_evidence_inside_the_current_claim_is_found
    row, gitlab = windowed_row(started_at: 2.days.ago, label_events_seen_until: nil)
    human_done_at(gitlab, 1.day.ago)

    assert_equal :done_added, scan(gitlab, row, POWERPANNE)&.reason
  end

  def test_evidence_before_the_floor_is_ignored
    row, gitlab = windowed_row(started_at: 10.days.ago, label_events_seen_until: 1.day.ago)
    human_done_at(gitlab, 2.days.ago)

    assert_nil scan(gitlab, row, POWERPANNE), 'the floor says that event was already accounted for'
  end

  def test_evidence_after_the_floor_is_found
    row, gitlab = windowed_row(started_at: 10.days.ago, label_events_seen_until: 1.day.ago)
    human_done_at(gitlab, 1.hour.ago)

    assert_equal :done_added, scan(gitlab, row, POWERPANNE)&.reason
  end

  def test_evidence_before_the_row_existed_is_ignored
    row, gitlab = windowed_row(created_at: 1.day.ago, started_at: nil, label_events_seen_until: nil)
    human_done_at(gitlab, 2.days.ago)

    assert_nil scan(gitlab, row, POWERPANNE), "a ticket's history before autodev tracked it is not a handover"
  end

  def test_a_row_reset_to_checking_pipeline_has_no_started_at_and_still_scans
    row, gitlab = claimed_row(POWERPANNE)
    ::Issue.reset_for_retry!(::Issue.where(id: row.id))

    assert_nil row.reload.started_at, 'precondition: the reset clears started_at'
    human!(gitlab, add: [DONE])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_equal :done_added, scan(gitlab, row, POWERPANNE)&.reason
  end

  def test_a_revived_row_has_no_started_at_and_still_scans
    row, gitlab = claimed_row(POWERPANNE)
    row.update_columns(status: 'fixing_discussions')
    ::Issue.revive_stalled!(::Issue.where(id: row.id))

    assert_nil row.reload.started_at, 'precondition: the revival clears started_at'
    human!(gitlab, add: [DONE])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_equal :done_added, scan(gitlab, row, POWERPANNE)&.reason
  end

  def test_a_closed_row_does_not_replay_the_handover_that_closed_it
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [DONE])
    travel 1.minute

    assert not_ours?(row, gitlab, POWERPANNE), 'precondition: the handover closes the row'

    travel 1.minute
    ::Issue.reset_for_retry!(::Issue.where(id: row.id))
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_nil scan(gitlab, row, POWERPANNE), 'the close accounted for every event before it'
  end

  # --- cost -------------------------------------------------------------

  def test_no_write_since_the_floor_costs_no_call
    row, gitlab = claimed_row(POWERPANNE)
    row.update_columns(labels_written_at: 2.days.ago, label_events_seen_until: 1.day.ago)

    assert_nil scan(gitlab, row, POWERPANNE)
    assert_equal 0, gitlab.event_calls
  end

  def test_a_row_never_scanned_is_due_at_its_first_write
    row, gitlab = claimed_row(POWERPANNE)
    row.update_columns(labels_written_at: 1.minute.ago, label_events_seen_until: nil)

    assert_nil scan(gitlab, row, POWERPANNE)
    assert_equal 1, gitlab.event_calls
  end

  def test_a_clean_scan_advances_the_floor_to_the_moment_before_the_read
    row, gitlab = cleanly_written_row
    before_read = Time.current
    gitlab.on_events_read { travel 10.seconds }

    assert_nil scan(gitlab, row, POWERPANNE)
    assert_in_delta before_read, floor_of(row), 1, 'the floor is the moment before the read, not after it'
  end

  def test_a_clean_scan_is_not_repeated_without_a_new_write
    row, gitlab = cleanly_written_row
    scan(gitlab, row, POWERPANNE)
    scan(gitlab, ::Issue.find(row.id), POWERPANNE)

    assert_equal 1, gitlab.event_calls, 'a second verdict with no write since reads nothing'
  end

  def test_a_write_during_the_read_makes_the_next_verdict_scan_again
    row, gitlab = claimed_row(POWERPANNE)
    autodev!(gitlab, POWERPANNE, :apply_label_done, row)
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row, after: 0)
    gitlab.on_events_read do
      travel 1.second
      ::Issue.where(id: row.id).update_all(labels_written_at: Time.current)
    end

    assert_nil scan(gitlab, row, POWERPANNE)
    assert_nil scan(gitlab, row, POWERPANNE)
    assert_equal 2, gitlab.event_calls
  end

  def test_a_stage_one_candidate_and_the_scan_share_one_read
    row, gitlab = claimed_row(POWERPANNE)
    autodev!(gitlab, POWERPANNE, :apply_label_done, row)

    assert_includes gitlab.labels, DONE, "precondition: autodev's own done is a stage-1 candidate"
    assert_nil scan(gitlab, row, POWERPANNE)
    assert_equal 1, gitlab.event_calls
  end

  def test_without_a_row_the_scan_never_runs
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: [DONE])
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_nil handover(gitlab, POWERPANNE).verdict(gitlab.issue(PATH, row.issue_iid), row.issue_iid)
    assert_equal 0, gitlab.event_calls
  end

  def test_a_failed_read_raises_and_leaves_the_floor_alone
    row, gitlab = claimed_row(POWERPANNE)
    row.update_columns(label_events_seen_until: 1.day.ago, labels_written_at: 1.minute.ago)
    floor = floor_of(row)
    gitlab.define_singleton_method(:issue_label_events) { |*| raise Errno::ECONNRESET, 'reset' }

    assert_raises(ApiUnavailableError) { scan(gitlab, row, POWERPANNE) }
    assert_equal floor, floor_of(row)
  end

  # --- the two stamps ---------------------------------------------------

  def test_every_label_write_stamps_the_row
    row, gitlab = claimed_row(POWERPANNE)
    %i[apply_label_todo apply_label_done apply_label_attention apply_label_doing].each do |write|
      row.update_columns(labels_written_at: nil)
      autodev!(gitlab, POWERPANNE, write, row)

      refute_nil ::Issue.find(row.id).labels_written_at, "#{write} wrote and must stamp"
    end
  end

  def test_a_write_skipped_as_a_no_op_does_not_stamp
    row, gitlab = claimed_row(POWERPANNE)
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row)

    assert_nil ::Issue.find(row.id).labels_written_at, 'the ticket already carried Doing (#75): nothing was written'
  end

  def test_another_project_with_the_same_iid_is_not_stamped
    row, gitlab = claimed_row(POWERPANNE)
    other = create_issue(project_path: 'other/project', issue_iid: row.issue_iid)
    autodev!(gitlab, POWERPANNE, :apply_label_done, row)

    assert_nil other.reload.labels_written_at
  end

  def test_a_failed_write_does_not_stamp
    row, gitlab = claimed_row(POWERPANNE)
    gitlab.define_singleton_method(:edit_issue) do |*, **|
      raise Gitlab::Error::ResponseError,
            Struct.new(:parsed_response, :code, :request)
                  .new('boom', 500, Struct.new(:base_uri, :path).new('https://gitlab.example', '/x'))
    end
    autodev!(gitlab, POWERPANNE, :apply_label_done, row)

    assert_nil ::Issue.find(row.id).labels_written_at
  end

  def test_entering_closed_stamps_the_floor_and_nothing_else_moves_it
    row = create_issue(status: 'fixing_discussions', label_events_seen_until: 3.days.ago)
    floor = row.reload.label_events_seen_until
    row.discussions_fixed!

    assert_equal floor, row.reload.label_events_seen_until

    row.close!

    assert_in_delta Time.current, row.reload.label_events_seen_until, 2
  end

  def test_the_migration_backfills_existing_rows_only_once
    row = create_issue(label_events_seen_until: nil)
    migration = AddLabelEventBookkeepingToIssues.new
    migration.verbose = false
    migration.up

    stamped = row.reload.label_events_seen_until

    refute_nil stamped
    travel 1.hour
    migration.up

    assert_equal stamped, row.reload.label_events_seen_until, 'a re-run on boot only fills NULL'
  end

  private

  # A row autodev has claimed: `Doing` posed by autodev a while ago, the scan
  # floor before that — the state a request sits in once `start_processing` ran.
  def claimed_row(config)
    gitlab = RecordingGitlab.new([])
    row = create_issue(status: 'fixing_discussions', mr_iid: 11, started_at: 1.hour.ago,
                       label_events_seen_until: 1.hour.ago)
    row.update_columns(created_at: 2.hours.ago)
    travel(-30.minutes) { manager(gitlab, config).send(:apply_label_doing, row.issue_iid) }
    row.update_columns(labels_written_at: nil)
    [row.reload, gitlab]
  end

  # A person's edit, a minute after whatever happened last.
  def human!(gitlab, **edit)
    travel 1.minute
    gitlab.human_edit(**edit)
  end

  # One of autodev's own label writes, through the real `LabelManager`.
  # `after:` is how long after the previous step it happens (a minute).
  def autodev!(gitlab, config, write, row, **opts)
    travel(opts.delete(:after) || 1.minute)
    manager(gitlab, config).send(write, row.issue_iid, **opts)
  end

  # A row whose clocks are set by hand, with autodev having just written.
  def windowed_row(**clocks)
    row, gitlab = claimed_row(POWERPANNE)
    row.update_columns(created_at: 30.days.ago, **clocks, labels_written_at: Time.current)
    [row, gitlab]
  end

  # A row autodev wrote on, with nothing of anybody else's to find and no
  # stage-1 candidate left, so every events read is the scan's.
  def cleanly_written_row
    row, gitlab = claimed_row(POWERPANNE)
    human!(gitlab, add: ['PM::Evolution'])
    autodev!(gitlab, POWERPANNE, :apply_label_done, row, after: 0)
    autodev!(gitlab, POWERPANNE, :apply_label_doing, row, after: 0)
    [row, gitlab]
  end

  def human_done_at(gitlab, time) = gitlab.push_event('add', DONE, HUMAN_ID, time.utc.iso8601(3))

  def floor_of(row) = ::Issue.find(row.id).label_events_seen_until

  def manager(gitlab, config)
    obj = Object.new
    obj.singleton_class.include(LabelManager)
    obj.instance_variable_set(:@client, gitlab)
    obj.instance_variable_set(:@project_config, config)
    obj.instance_variable_set(:@project_path, PATH)
    obj.instance_variable_set(:@logger, nil)
    obj.define_singleton_method(:log) { |*| nil }
    obj.define_singleton_method(:log_error) { |*| nil }
    obj
  end

  def handover(gitlab, config)
    Autodev::LabelHandover.new(client: gitlab, path: PATH, project_config: config, logger: StubLogger.new)
  end

  def scan(gitlab, row, config)
    handover(gitlab, config).verdict(gitlab.issue(PATH, row.issue_iid), row.issue_iid, row: row)
  end

  def not_ours?(row, gitlab, config)
    Autodev::HandoverStop.new(client: gitlab, path: PATH, project_config: config, logger: StubLogger.new)
                         .not_ours?(row.reload, gitlab.issue(PATH, row.issue_iid))
  end

  def expected_note(key, label)
    Locales.t(key, locale: :fr, tag: ::ActivityLogger.tag, label_todo: 'To Do', label: label)
  end
end
