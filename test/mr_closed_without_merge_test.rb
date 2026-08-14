# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# What ending does a merge request that is no longer open give its ticket?
# (Autodev #66)
#
# `poll_open_mr` routes every state that is not `opened` to `handle_mr_closed`,
# which posed the end label unconditionally. But `merged` and `closed` are
# opposite outcomes: merged means the work is in the target branch, closed
# without merging means nothing was delivered — and on powerpanne/core the end
# label is `Development::Awaiting Feature Review`, so a human who rejected the
# work by closing its MR put the ticket on the PM's review board announced as
# ready for review.
#
# Worse than the label: the row was left `needs_attention: false`, which is
# exactly the discriminator `dispatch_done_unassigned` reads. The
# `post_completion` hook — the guard Autodev #60 put there so a deploy never runs
# on work autodev did not deliver — did not apply to this route. No project
# configures `post_completion` today, so that was a latent deploy of rejected
# work, not a live one.
#
# So the split: `merged` keeps the delivery ending, everything else is a give-up
# and goes through the shared abandon point. The label half of that (and its
# no-`label_attention` fallback) is asserted for this path alongside the other
# five in `test/abandon_attention_label_test.rb`; this file owns the split
# itself.
class MrClosedWithoutMergeTest < Minitest::Test
  include DatabaseTestHelper

  # The real powerpanne/core shape: `label_done` is the "ready for feature
  # review" column, which is what makes posing it on a rejected MR a lie.
  BASE_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                  'label_doing' => 'Development::Doing',
                  'label_done' => 'Development::Awaiting Feature Review' }.freeze
  ATTENTION = 'Development::StandBy'
  WITH_ATTENTION = BASE_CONFIG.merge('label_attention' => ATTENTION).freeze

  AUTHOR_ID = 42
  MR_URL = 'http://gitlab/mr/7'

  # Records everything crossing the GitLab boundary so the real LabelManager /
  # IssueNotifier / ActivityLogger / IssueAbandonment code runs.
  class FakeClient
    GlIssue = Struct.new(:labels, :id)
    GlMr = Struct.new(:state)
    Note = Struct.new(:id, :body)

    attr_reader :edits, :notes

    def initialize(mr_state, labels = ['To do', 'Development::Doing'])
      @mr_state = mr_state
      @labels = labels
      @edits = []
      @notes = []
    end

    def merge_request(_path, _iid) = GlMr.new(state: @mr_state)
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

  # Driven through `poll_open_mr`, not `handle_mr_closed`, so the test still
  # fails if the routing itself changes: the whole defect was one route serving
  # two opposite outcomes.
  def poll(mr_state, project_config: WITH_ATTENTION)
    @client = FakeClient.new(mr_state)
    issue = create_issue(mr_iid: 7, mr_url: MR_URL, issue_author_id: AUTHOR_ID, locale: 'fr')
    advance_to(issue, 'checking_pipeline')
    worker(project_config).send(:poll_open_mr, issue)
    issue.reload
  end

  def worker(project_config)
    PipelineMonitor.allocate.tap do |instance|
      instance.send(:init_runner, client: @client, config: {}, project_config: project_config,
                                  logger: NullLogger.new, token: 'tok')
    end
  end

  # Every `labels:` payload the run sent to GitLab, newest last, split back into
  # the label list `manage_labels` joined.
  def labels_sent
    @client.edits.filter_map { |(_, attrs)| attrs[:labels]&.split(',') }
  end

  def handed_back? = @client.edits.map(&:last).include?({ assignee_ids: [AUTHOR_ID] })

  # --- merged: the delivery, which must not change --------------------------
  #
  # Without these, a future edit could give both states the give-up ending and
  # nothing would notice that autodev stopped announcing its own deliveries.

  def test_a_merged_mr_still_poses_the_end_label
    poll('merged')

    assert_equal [[BASE_CONFIG['label_done']]], labels_sent
  end

  def test_a_merged_mr_is_a_delivery_and_is_not_flagged
    issue = poll('merged')

    assert_equal ['done', false, nil],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  def test_a_merged_mr_stamps_finished_at
    refute_nil poll('merged').finished_at
  end

  # A delivery is not a give-up: nothing is handed back, because autodev did the
  # job it was asked to do.
  def test_a_merged_mr_is_not_handed_back_to_its_author
    poll('merged')

    refute_predicate self, :handed_back?, 'a merged MR handed the ticket back as if autodev had given up'
  end

  # The activity line this path posts had no template at all — production shows
  # `- 07-23 15:14 — activity_mr_closed` on the two tickets that reached it.
  def test_a_merged_mr_logs_a_localized_activity_line
    poll('merged')

    refute(@client.notes.any? { |body| body.include?('activity_mr_closed') },
           'the merged activity line rendered its raw i18n key')
  end

  # --- closed without merging: nothing was delivered ------------------------

  def test_a_closed_mr_does_not_announce_the_ticket_as_ready_for_review
    poll('closed')

    refute_includes labels_sent.flatten, BASE_CONFIG['label_done'],
                    'a rejected MR presented its ticket as ready for feature review'
  end

  def test_a_closed_mr_poses_the_attention_label
    poll('closed')

    assert_equal [[ATTENTION]], labels_sent
  end

  # The Autodev #63 fallback, inherited rather than reimplemented: with no
  # `label_attention` configured — the state of both real projects today — no end
  # label is posed at all and the row keeps `label_doing`.
  def test_a_closed_mr_leaves_the_label_alone_with_no_attention_label
    poll('closed', project_config: BASE_CONFIG)

    assert_empty labels_sent
  end

  # The load-bearing half. `needs_attention` is what `dispatch_done_unassigned`
  # reads, so raising it is what keeps a rejected MR out of the `post_completion`
  # hook's population.
  def test_a_closed_mr_flags_the_row_with_its_own_reason
    issue = poll('closed')

    assert_equal ['done', true, 'mr_closed_unmerged'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  # Not `stagnation_pipeline`: `dispatch_infra_recheck` selects exactly that
  # value and re-arms the row, and a human closing the MR is a decision, not a
  # deferral.
  def test_the_reason_is_not_the_one_that_re_arms_the_row
    refute_equal 'stagnation_pipeline', poll('closed').attention_reason
  end

  def test_a_closed_mr_stamps_finished_at
    refute_nil poll('closed').finished_at
  end

  # A `done` row is outside `dispatch_unassignment`'s ACTIVE_STATUSES sweep and
  # outside the dormant audit's three arms, so nothing else will ever hand the
  # ticket back: left on autodev it belongs to nobody. The human who closed the
  # MR is not necessarily its author either.
  def test_a_closed_mr_is_handed_back_to_its_author
    poll('closed')

    assert_predicate self, :handed_back?, 'a rejected MR left its ticket assigned to autodev'
  end

  # And the comment is what explains the handback the author did not ask for.
  def test_a_closed_mr_explains_itself_and_the_handback_on_the_issue
    poll('closed')

    assert(@client.notes.any? { |body| body.include?(MR_URL) },
           'no comment named the MR autodev stopped following')
    assert(@client.notes.any? { |body| body.include?(Locales.t(:abandon_reassigned, locale: :fr)) },
           'the ticket changed hands without the comment saying so')
  end

  # Any state GitLab adds later lands here too. The predicate that matters is
  # "was this delivered", not an enumeration of GitLab's vocabulary: erring
  # towards "a human should look" is recoverable, erring towards "ready for
  # feature review" is not.
  #
  # This used to be asserted on `locked`, which was wrong for a different reason
  # (Autodev #69): `locked` is not an unknown state, it is GitLab's documented
  # transitional one, and a poll landing in that window abandoned an MR being
  # delivered. It no longer reaches `handle_mr_closed` at all —
  # `test/locked_mr_is_not_a_verdict_test.rb` owns that — so the rule is pinned
  # here on a state that is genuinely unknown, which is what it was always about.
  def test_any_state_that_is_not_merged_is_treated_as_undelivered
    issue = poll('quantum_superposed')

    assert_equal [true, 'mr_closed_unmerged'], [issue.needs_attention, issue.attention_reason]
  end

  # --- the strings the new reason needs ------------------------------------
  #
  # `Locales.t` answers a missing key with the key itself, so a forgotten
  # template surfaces as `mr_closed_unmerged` in a GitLab comment rather than as
  # an exception. Three sinks, two locales.
  def test_the_new_reason_has_a_template_in_both_locales_for_all_three_sinks
    %i[fr en].each do |locale|
      %i[mr_closed_unmerged activity_mr_closed_unmerged
         web_errors_explain_attention_mr_closed_unmerged].each do |key|
        rendered = Locales.t(key, locale: locale, tag: 'tag', mr_url: MR_URL, detail: '')

        refute_equal key.to_s, rendered, "#{key} has no #{locale} template"
      end
    end
  end
end
