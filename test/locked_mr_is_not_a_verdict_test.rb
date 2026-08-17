# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# `locked` is a wait, not a verdict (Autodev #69).
#
# GitLab's merge request state machine declares exactly four states — `opened`,
# `closed`, `merged`, `locked` (`app/models/merge_request.rb`, `state_machine
# :state_id`) — and `locked` is the only one that says nothing about the
# outcome. `MergeRequests::MergeService` wraps the whole merge in
# `merge_request.in_locked_state`, so the state is entered from `opened` and left
# either for `merged` or back for `opened`. GitLab's own REST documentation puts
# it plainly: "Searching by `locked` generally returns no results as that state
# is short-lived and transitional."
#
# Since Autodev #66 the split in `handle_mr_closed` is on "was this delivered",
# and everything that is not `merged` goes to the shared abandon point. That is
# the right default for an *unknown* state and this file keeps it. But `locked`
# is not unknown: a poll landing in that window abandoned an MR that was in the
# middle of being delivered — a public comment saying it had been closed without
# being merged, which was false, the ticket handed back to its author,
# `needs_attention`, and no end label.
#
# So `locked` joins `RUNNING_STATUSES`: leave the poll without concluding
# anything and let the next cycle decide. The half of this file that matters as
# much as the fix is the second one — `merged` still delivers, `closed` still
# gives up, and a state GitLab has not invented yet still gives up. Without
# those, taking `locked` out of the abandon category could widen the door
# unnoticed.
class LockedMrIsNotAVerdictTest < Minitest::Test
  include DatabaseTestHelper

  # The real powerpanne/core shape: `label_done` is the "ready for feature
  # review" column, which is what makes posing it — or its `label_attention`
  # counterpart — on an MR mid-merge a statement about work nobody decided on.
  BASE_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                  'label_doing' => 'Development::Doing',
                  'label_done' => 'Development::Awaiting Feature Review' }.freeze
  ATTENTION = 'Development::StandBy'
  WITH_ATTENTION = BASE_CONFIG.merge('label_attention' => ATTENTION).freeze

  AUTHOR_ID = 42
  MR_URL = 'http://gitlab/mr/7'

  # A state nobody has to invent a meaning for: this is the "GitLab added
  # something tomorrow" case, and it must keep going to the abandon point.
  UNKNOWN_STATE = 'quantum_superposed'

  # Counts its own reads, so "the pipeline of an MR being merged is not the
  # question" is an assertion rather than a comment.
  class GlMr
    attr_reader :state, :head_pipeline_reads

    def initialize(state)
      @state = state
      @head_pipeline_reads = 0
    end

    def head_pipeline
      @head_pipeline_reads += 1
      nil
    end
  end

  # Records everything crossing the GitLab boundary so the real LabelManager /
  # IssueNotifier / ActivityLogger / IssueAbandonment code runs — the point being
  # that a give-up is visible here whether or not the row's columns change.
  class FakeClient
    GlIssue = Struct.new(:labels, :id)
    Note = Struct.new(:id, :body)

    attr_reader :edits, :notes, :mr

    def initialize(mr_state, labels = ['To do', 'Development::Doing'])
      @mr = GlMr.new(mr_state)
      @labels = labels
      @edits = []
      @notes = []
    end

    def merge_request(_path, _iid) = @mr
    def issue(_path, _iid) = GlIssue.new(labels: @labels.dup, id: 1)
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
  end

  # Driven through `poll_open_mr`, like the Autodev #66 file, so the test still
  # fails if the *routing* changes rather than the handler: the defect was which
  # route a state took.
  #
  # `watched_for:` back-dates `checking_pipeline_since` — the clock the age bound
  # reads — after the AASM callback has stamped it.
  def poll(mr_state, project_config: WITH_ATTENTION, watched_for: nil, config: {})
    @client = FakeClient.new(mr_state)
    issue = create_issue(mr_iid: 7, mr_url: MR_URL, issue_author_id: AUTHOR_ID, locale: 'fr')
    advance_to(issue, 'checking_pipeline')
    issue.update_columns(checking_pipeline_since: watched_for.ago) if watched_for
    worker(project_config, config).send(:poll_open_mr, issue)
    issue.reload
  end

  def worker(project_config, config = {})
    PipelineMonitor.allocate.tap do |instance|
      instance.send(:init_runner, client: @client, config: config, project_config: project_config,
                                  logger: NullLogger.new, token: 'tok')
      # What `check` does at the top of every poll; `poll_open_mr` alone would
      # leave the flag the age bound reads undefined.
      instance.send(:clear_poll_verdict)
    end
  end

  # Every `labels:` payload the run sent to GitLab, newest last, split back into
  # the label list `manage_labels` joined.
  def labels_sent
    @client.edits.filter_map { |(_, attrs)| attrs[:labels]&.split(',') }
  end

  def handed_back? = @client.edits.map(&:last).include?({ assignee_ids: [AUTHOR_ID] })

  # --- locked: a wait, exactly like a running pipeline ----------------------

  def test_a_locked_mr_stays_in_the_pipeline_watch
    assert_equal 'checking_pipeline', poll('locked').status
  end

  def test_a_locked_mr_is_not_flagged_as_needing_attention
    issue = poll('locked')

    assert_equal [false, nil, nil],
                 [issue.needs_attention, issue.attention_reason, issue.finished_at]
  end

  # The load-bearing one: the comment said the MR had been closed without being
  # merged, on an MR GitLab was in the middle of merging.
  def test_a_locked_mr_says_nothing_on_the_issue
    poll('locked')

    assert_empty @client.notes, 'a mid-merge MR was announced as closed without being merged'
  end

  def test_a_locked_mr_poses_no_end_label
    poll('locked')

    assert_empty labels_sent
  end

  def test_a_locked_mr_is_not_handed_back_to_its_author
    poll('locked')

    refute_predicate self, :handed_back?, 'a mid-merge MR handed its ticket back as if autodev had given up'
  end

  # A transient state is not the open path either: there is no verdict to read
  # from the head pipeline of an MR being merged.
  def test_a_locked_mr_pipeline_is_not_examined
    poll('locked')

    assert_equal 0, @client.mr.head_pipeline_reads
  end

  # --- the wait is still bounded (Autodev #53) ------------------------------
  #
  # `poll_open_mr` returns early on every state that is not `opened`, so a
  # `locked` MR reaching `abandon_expired_watch` is not free — it is the reason
  # the transient branch has to fall through to the bound instead of returning.
  # Without it, an MR wedged in `locked` would be polled forever, which is the
  # unbounded tail Autodev #53 exists to close.

  def test_a_locked_mr_under_the_bound_is_left_to_the_next_cycle
    assert_equal 'checking_pipeline', poll('locked', watched_for: 3.days).status
  end

  def test_a_locked_mr_wedged_past_the_bound_is_given_up
    issue = poll('locked', watched_for: 20.days)

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  # And it is given up as an expired watch, not as a closed MR: the reason is
  # what the GitLab comment and the activity line are keyed off.
  def test_the_wedged_locked_mr_is_not_reported_as_a_closed_merge_request
    poll('locked', watched_for: 20.days)

    refute(@client.notes.any? { |body| body.include?('mr_closed_unmerged') },
           'the expired watch borrowed the closed-MR template')
  end

  # --- what must not change ------------------------------------------------

  def test_a_merged_mr_is_still_a_delivery
    issue = poll('merged')

    assert_equal ['done', false, nil], [issue.status, issue.needs_attention, issue.attention_reason]
    assert_equal [[BASE_CONFIG['label_done']]], labels_sent
  end

  def test_a_closed_mr_is_still_a_give_up
    issue = poll('closed')

    assert_equal ['done', true, 'mr_closed_unmerged'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
    assert_equal [[ATTENTION]], labels_sent
  end

  # The Autodev #66 rule, kept: erring towards "a human should look" is
  # recoverable, erring towards "ready for feature review" is not. Taking
  # `locked` out of that category must not take anything else out with it.
  def test_a_state_gitlab_has_not_invented_yet_is_still_a_give_up
    issue = poll(UNKNOWN_STATE)

    assert_equal ['done', true, 'mr_closed_unmerged'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
    assert_predicate self, :handed_back?, 'an unknown MR state left its ticket assigned to autodev'
  end

  def test_an_unknown_state_never_announces_the_ticket_as_ready_for_review
    poll(UNKNOWN_STATE)

    refute_includes labels_sent.flatten, BASE_CONFIG['label_done']
  end

  # The wait list is an allow-list, and pinning it is what makes adding to it a
  # decision. `locked` is the only one of GitLab's four states that carries no
  # verdict; `all` in the GraphQL `MergeRequestState` enum is a filter value the
  # API never returns for a single MR.
  def test_only_gitlabs_transitional_state_is_treated_as_a_wait
    assert_equal %w[locked], PipelineMonitor::MrStateChecker::TRANSIENT_MR_STATES
  end
end
