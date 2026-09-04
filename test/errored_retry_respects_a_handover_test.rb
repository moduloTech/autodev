# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Autodev #102. dispatch_unassignment sweeps ACTIVE_STATUSES and `error` is not
# in it, so an errored row was never asked whether a human had taken the ticket
# back — and `error` is exactly the state where that is most likely: autodev
# failed, the ticket carries label_attention or stayed on label_doing, and
# somebody who sees that moves it into their own column.
#
# dispatch_retries then relaunched the row, restore_working_label re-applied
# autodev's working label on a ticket somebody was holding, and the takeover was
# only detected a cycle later — after the write, and possibly after a delivery.
class ErroredRetryRespectsAHandoverTest < Minitest::Test
  include DatabaseTestHelper

  AUTODEV_ID = 7
  AUTHOR_ID = 42

  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Doing', 'label_done' => 'Done' }.freeze

  FakeGlIssue = Struct.new(:labels)
  FakeLabel = Struct.new(:name)
  FakeUser = Struct.new(:id)
  FakeEvent = Struct.new(:label, :action, :user)
  FakeNote = Struct.new(:id)

  # `taken_over: true` makes GitLab answer with `label_done` already applied by
  # somebody who is not autodev — the `done_added` suspicion `LabelHandover`
  # resolves against the resource label events. `raises:` models a GitLab read
  # that could not answer at all.
  class StubClient
    def initialize(taken_over: false, raises: nil)
      @taken_over = taken_over
      @raises = raises
    end

    def issue(_path, _iid)
      raise @raises if @raises

      FakeGlIssue.new(@taken_over ? ['Done'] : ['Doing'])
    end

    def issue_label_events(_path, _iid)
      return [] unless @taken_over

      [FakeEvent.new(FakeLabel.new('Done'), 'add', FakeUser.new(AUTHOR_ID))]
    end

    def create_issue_note(_path, _iid, _body) = FakeNote.new(1)
  end

  def setup
    setup_database
    @issue = ::Issue.create!(project_path: 'group/project', issue_iid: 1, status: 'error',
                             mr_iid: 11_333, next_retry_at: 1.hour.ago, retry_count: 1)
  end

  def test_a_taken_over_ticket_is_not_relaunched
    run_retry_with_handover(taken_over: true)
    @issue.reload

    assert_equal 'closed', @issue.status, 'a ticket somebody holds must not be relaunched'
    assert_empty labels_written, 'and autodev must not repose its working label on it'
  end

  def test_an_untouched_ticket_is_relaunched_exactly_as_before
    run_retry_with_handover(taken_over: false)
    @issue.reload

    assert_equal 'checking_pipeline', @issue.status
    refute_empty labels_written, 'the nominal path must be unchanged'
  end

  def test_a_gitlab_read_that_fails_leaves_the_row_untouched
    run_retry_with_handover(raises: ::ApiUnavailableError.new(:issue, StandardError.new('gitlab is down')))
    @issue.reload

    assert_equal 'error', @issue.status,
                 'a read that could not answer is not permission to relaunch'
    assert_empty labels_written
  end

  # Autodev #102, design §4: HandoverStop must add no logic of its own — every
  # method beyond the question it forwards is an answer free to drift from
  # PollDispatcher's.
  def test_handover_stop_adds_no_logic_of_its_own
    own = Autodev::HandoverStop.instance_methods(false) - [:stop_on_handover]

    assert_empty own, 'HandoverStop carries ivars; any method here is an answer free to drift'
  end

  private

  def run_retry_with_handover(**client_opts)
    @posed = []
    client = StubClient.new(**client_opts)
    job = IssueProcessJob.new
    job.define_singleton_method(:build_client) { |*| client }

    ::GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
      ::MrFixer.stub(:new, label_recorder) do
        job.send(:perform_retry_errored, @issue, CONFIG, PROJECT_CONFIG)
      end
    end
  end

  def label_recorder
    posed = @posed
    Object.new.tap { |rec| rec.define_singleton_method(:apply_label_doing) { |_iid| posed << :doing } }
  end

  def labels_written = @posed
end
