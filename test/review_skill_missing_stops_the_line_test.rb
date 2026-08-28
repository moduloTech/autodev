# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'

# A `review_skill` the clone has no `SKILL.md` for names its own cause, and the
# request stops there (Autodev #81).
#
# Autodev #74 left this case escaping `launch_review` on purpose: rescuing it and
# handing the row back to `checking_pipeline` writes an activity row on every
# poll, which keeps the row out of `DormantAudit`'s active arm *forever* and
# restarts the age clock each time — an unbounded, unsignalled loop, strictly
# worse than parking the row in `reviewing`.
#
# The trap is real, and the way out is not to rescue-and-resume: it is to rescue
# and **stop**. The row goes through the shared abandon point, so it reaches
# `done` + `needs_attention` with a reason that names the misconfigured skill —
# and `done` is a state no dispatch pass re-arms, so nothing is written on any
# later poll. That is the property this file pins: not "the reason is posed", but
# "the reason is posed AND the row is out of every pass's population".
# rubocop:disable Metrics/ClassLength -- the two halves of the ruling only read
# together: the cause is named (four sinks) AND the line stops (four properties).
# Splitting them into two files would put the trap and its remedy apart.
class ReviewSkillMissingStopsTheLineTest < Minitest::Test
  include DatabaseTestHelper

  SKILL = 'prepare-mr'
  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Doing', 'label_done' => 'Done',
                     'label_attention' => 'StandBy', 'review_skill' => SKILL }.freeze

  # Records everything crossing the GitLab boundary so the real LabelManager /
  # IssueNotifier / ActivityLogger run rather than being stubbed out.
  class FakeClient
    GlIssue = Struct.new(:labels, :id)
    Note = Struct.new(:id, :body)

    attr_reader :edits, :notes

    def initialize
      @edits = []
      @notes = []
    end

    def issue(_path, _iid) = GlIssue.new(labels: ['To do', 'Doing'], id: 1)
    def user = GlIssue.new(labels: [], id: 999)

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

  # A monitor whose skill review raises exactly what `prepare_review_clone`
  # raises when the declared skill has no SKILL.md in the clone. Everything below
  # `review_with_skill` is the part this file is not about; everything above it —
  # `launch_review` and the abandon point — is the real code.
  def monitor(raising: nil)
    PipelineMonitor.allocate.tap do |mon|
      mon.send(:init_runner, client: @client, config: {}, project_config: PROJECT_CONFIG,
                             logger: NullLogger.new, token: 'tok')
      error = raising || MissingReviewSkillError.new(SKILL, '/tmp/work')
      mon.define_singleton_method(:review_with_skill) { |_| raise error }
    end
  end

  def reviewing_issue
    Issue.create!(project_path: 'group/project', issue_iid: 4242, mr_iid: 7,
                  mr_url: 'http://gitlab/mr/7', issue_author_id: 42, status: 'reviewing',
                  review_count: 0, review_failure_count: 0, locale: 'fr')
  end

  def transitions_for(issue)
    ActivityEvent.where(issue_id: issue.id, kind: 'transition')
                 .map { |event| JSON.parse(event.payload_json)['event'] }
  end

  def activity_keys(issue)
    ActivityEvent.where(issue_id: issue.id, kind: 'danger_claude')
                 .map { |event| JSON.parse(event.payload_json)['key'] }
  end

  # --- the cause is named, at the point of the raise -----------------------

  def test_the_row_carries_a_reason_that_names_the_misconfiguration
    row = reviewing_issue
    monitor.send(:launch_review, row)

    assert_equal [true, 'review_skill_missing'],
                 [row.reload.needs_attention, row.attention_reason]
  end

  def test_the_gitlab_comment_names_the_skill_and_the_path_it_expected
    row = reviewing_issue
    monitor.send(:launch_review, row)

    posted = @client.notes.join("\n")

    assert_includes posted, SKILL
    assert_includes posted, ".claude/skills/#{SKILL}/SKILL.md"
  end

  def test_the_activity_line_records_the_cause
    row = reviewing_issue
    monitor.send(:launch_review, row)

    assert_includes activity_keys(row), 'review_skill_missing'
  end

  def test_the_ticket_is_handed_back_to_its_author
    row = reviewing_issue
    monitor.send(:launch_review, row)

    assert_includes @client.edits.map(&:last), { assignee_ids: [42] }
  end

  # `label_done` reads "ready for feature review" on the configured projects, and
  # nothing was reviewed here (Autodev #63).
  def test_the_give_up_poses_the_attention_label_not_the_end_label
    row = reviewing_issue
    monitor.send(:launch_review, row)

    posed = @client.edits.map(&:last).filter_map { |attrs| attrs[:labels] }.join(',')

    assert_includes posed, 'StandBy'
    refute_includes posed, 'Done'
  end

  # --- and the line stops there --------------------------------------------

  def test_the_line_is_stopped_rather_than_parked_in_reviewing
    row = reviewing_issue
    monitor.send(:launch_review, row)

    assert_equal 'done', row.reload.status
  end

  # The trap the ticket is explicit about. Three passes could re-arm a row, and
  # each is excluded by a different property — so this asserts the properties,
  # not the absence of a symptom:
  #
  #   * `dispatch_pipelines` selects `checking_pipeline` — the row is `done`;
  #   * `dispatch_done_unassigned` selects `done` rows NOT flagged — it is flagged;
  #   * `dispatch_infra_recheck` selects `stagnation_pipeline` — the reason is its own.
  def test_the_row_sits_in_no_dispatch_pass_population # rubocop:disable Minitest/MultipleAssertions
    row = reviewing_issue
    monitor.send(:launch_review, row)
    row.reload

    refute_includes Autodev::PollDispatcher::ACTIVE_STATUSES, row.status
    assert_equal 'done', row.status
    assert row.needs_attention
    refute_equal 'stagnation_pipeline', row.attention_reason
  end

  # The give-up itself must not be replayable. Nothing in production can call the
  # review twice on this row — `done` leaves every dispatch pass's population, as
  # above — but `whiny_transitions: false` answers an impossible event with a
  # silent no-op, and running the side effects after one is the Autodev #61 class
  # of bug. So the abandon's own outputs are pinned at exactly one each: one
  # `abandon` transition, one GitLab comment, one `review_skill_missing` line.
  def test_a_second_pass_fires_no_second_abandon
    row = reviewing_issue
    monitor.send(:launch_review, row)
    monitor.send(:launch_review, row.reload)

    assert_equal 1, transitions_for(row).count('abandon')
    assert_equal 1, activity_keys(row).count('review_skill_missing')
  end

  def test_a_second_pass_posts_no_second_comment
    row = reviewing_issue
    monitor.send(:launch_review, row)
    notes_before = @client.notes.size

    monitor.send(:launch_review, row.reload)

    assert_equal notes_before, @client.notes.size
    assert_equal 'done', row.reload.status
  end

  # The general ruling of Autodev #74 is unchanged: only the *named* cause is
  # rescued. Any other `ConfigError` out of the review keeps escaping, because
  # nothing here knows what it means or how to stop the line for it.
  def test_an_unnamed_config_error_still_escapes
    row = reviewing_issue
    mon = monitor(raising: ConfigError.new('something else entirely'))

    assert_raises(ConfigError) { mon.send(:launch_review, row) }
    assert_equal 'reviewing', row.reload.status
  end

  # Neither counter moves: the review never ran, so it neither succeeded nor
  # failed. Spending `review_failure_count` here would also spend the five-strikes
  # budget on a configuration fault that five more attempts cannot clear.
  def test_neither_review_counter_is_spent
    row = reviewing_issue
    monitor.send(:launch_review, row)

    assert_equal [0, 0], [row.reload.review_count, row.review_failure_count]
  end
end
# rubocop:enable Metrics/ClassLength
