# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'

# Autodev #95, third of three files — see
# `an_invalid_request_is_not_an_outage_test.rb` for the classification and
# `a_refused_position_falls_back_to_a_comment_test.rb` for the fallback that
# stops most refusals ever reaching here.
#
# Autodev #91's shape, one endpoint over: count the occurrences of the *same*
# cause, and past `stagnation_threshold` give the request up under a reason that
# names it. Nothing re-arms it — an abandon is terminal (Autodev #53, #63) — and
# that is the property that makes rescuing this safe at all: a row handed back to
# `checking_pipeline` writes an activity line every cycle, which takes it out of
# `DormantAudit`'s active arm for ever.
#
# rubocop:disable Metrics/ClassLength -- half of these lines are the one GitLab
# stub that lets a real `check` and a real `fix` run far enough to reach the
# rescue under test, which is what makes the boundary the real one.
class ARefusedRequestIsBoundedAndSignalledTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'

  FakeMr = Struct.new(:iid, :state, :target_branch, :head_pipeline)
  FakePipeline = Struct.new(:id, :status)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class StubClient
    Note = Struct.new(:id, :body)
    GlIssue = Struct.new(:labels, :id)

    attr_reader :notes, :edits

    def initialize
      @notes = []
      @edits = []
    end

    def merge_request(_path, iid)
      ARefusedRequestIsBoundedAndSignalledTest::FakeMr.new(
        iid, 'opened', 'master', ARefusedRequestIsBoundedAndSignalledTest::FakePipeline.new(9, 'success')
      )
    end

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
      Note.new(@notes.size, body)
    end

    def issue_note(_path, _iid, note_id) = Note.new(note_id, @notes.last.to_s)

    def edit_issue_note(_path, _iid, _note_id, body)
      @notes[-1] = body
      Note.new(1, body)
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

  def setup = setup_database

  def threshold = 5

  def refusal(what: :mr_note, code: 400, message: 'Note {:line_code=>["must be a valid line code"]}')
    InvalidRequestError.new(
      what,
      Gitlab::Error::ResponseError.new(
        FakeResponse.new(message, code, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
      ),
      code
    )
  end

  def outage
    ApiUnavailableError.new(
      :mr_note,
      Gitlab::Error::ResponseError.new(
        FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
      )
    )
  end

  # --- the pipeline watch ---------------------------------------------------

  def test_one_refused_poll_leaves_the_row_where_it_was
    row = watched_issue
    poll(row)

    assert_equal 'checking_pipeline', row.reload.status
    refute row.needs_attention
  end

  def test_the_refusal_is_bounded_by_the_stagnation_threshold
    row = watched_issue
    (threshold - 1).times { poll(row) }

    assert_equal 'checking_pipeline', row.reload.status, 'given up before the threshold'

    poll(row)

    assert_equal %w[done gitlab_refused_request], [row.reload.status, row.attention_reason]
  end

  # The review is not blamed. It ran, it produced its findings, and it is only the
  # posting GitLab refused — so the counter that moves is this one and not
  # `review_failure_count`, whose give-up says "the review failed" and would be
  # the lie Autodev #85 is about.
  def test_the_review_failure_budget_is_not_spent
    row = watched_issue
    threshold.times { poll(row) }

    assert_equal 0, row.reload.review_failure_count.to_i
  end

  # Signalled, not merely stopped: the operator is told which call GitLab refused
  # and what it said, on the ticket itself.
  def test_the_give_up_names_the_refusal_on_the_ticket
    row = watched_issue
    client = nil
    threshold.times { client = poll(row) }

    assert_includes client.notes.join("\n"), 'mr_note'
  end

  # Constat 2 of the neutral review. Nothing on this path reads `has_conflicts`,
  # `merge_status` or `detailed_merge_status` — `ReviewArrearsSweep` does, this
  # does not — so the only cause autodev can name is the one GitLab handed it.
  # It used to supply one anyway ("the commonest cause is a merge request in
  # conflict"), on a client's ticket, for a call that may have nothing to do with
  # a review: a refused `mr_discussions` read is the same diagnosis with no
  # finding in play at all.
  def test_the_give_up_quotes_gitlab_instead_of_supposing_a_cause
    row = fixing_issue
    client = nil
    threshold.times do
      client = fix(row, error: refusal(what: :mr_discussions, message: 'Scope must be one of: all, resolved'))
    end
    comment = client.notes.join("\n")

    assert_includes comment, 'mr_discussions'
    assert_includes comment, 'Scope must be one of'
    refute_match(/conflict|conflit|finding|constat/i, comment)
  end

  # Constat 3. `ConsecutiveOccurrences` restarts a count when the *signature*
  # changes and on nothing else: a cycle that refused nothing writes no occurrence,
  # so it neither adds to the count nor clears it, and outside a human re-arm
  # nothing empties `stagnation_signatures`. The behaviour is #91's and is kept —
  # five refusals of the same call are five refusals of the same call, whenever
  # they happened — but the sentence a human reads may not turn that into "five
  # polls in a row", which is a different and false claim.
  def test_a_poll_that_refused_nothing_neither_clears_nor_counts
    row = watched_issue
    client = refuse_across_a_healthy_poll(row)

    assert_equal %w[done gitlab_refused_request], [row.reload.status, row.attention_reason]
    refute_match(/de suite|in a row|running|consecutive/i, client.notes.join("\n"))
  end

  def test_the_give_up_hands_the_ticket_back_to_its_author
    row = watched_issue
    client = nil
    threshold.times { client = poll(row) }

    assert_includes client.edits.map { |(_iid, attrs)| attrs[:assignee_ids] }, [42]
  end

  # A different refusal is a different fact, exactly like a pipeline whose failing
  # job set changes, or a base whose branch name changes (Autodev #91).
  def test_a_different_cause_restarts_the_count
    row = watched_issue
    threshold.times { |n| poll(row, error: refusal(message: "refusal number #{n}")) }

    assert_equal 'checking_pipeline', row.reload.status
  end

  def test_a_different_endpoint_restarts_the_count
    row = watched_issue
    threshold.times { |n| poll(row, error: refusal(what: :"endpoint_#{n}")) }

    assert_equal 'checking_pipeline', row.reload.status
  end

  # The crest line of Autodev #67: an outage may never end a request, however
  # often it repeats. Only GitLab's own refusal counts.
  def test_an_outage_is_never_given_up_on
    row = watched_issue
    (threshold * 3).times { poll(row, error: outage) }

    assert_equal 'checking_pipeline', row.reload.status
    assert_nil row.attention_reason
  end

  # --- the neighbouring verdict, instructed and left alone -----------------

  # The ticket asked whether `:inconclusive` — the review that could not be
  # published because GitLab had not computed `diff_refs` yet — needs a bound of
  # its own. It does not, and the reason is worth pinning rather than asserting in
  # prose: it ends the poll **normally**, so `abandon_expired_watch` (the last
  # statement of `poll_open_mr`) is reached, and `restore_watch_clock` has put back
  # the `checking_pipeline_since` the poll started with, so the true age is the one
  # the bound reads. It is capped at `pipeline_watch_max_days` and signalled as
  # `pipeline_watch_expired`.
  #
  # That is precisely what the refusal did *not* have: it left by exception, and
  # the exception skipped the bound. The difference is the whole ticket, which is
  # why the two live in one file.
  def test_an_inconclusive_review_is_still_capped_by_the_pipeline_watch
    row = watched_issue
    row.update(checking_pipeline_since: 30.days.ago)

    poll(row, outcome: :inconclusive)

    assert_equal %w[done pipeline_watch_expired], [row.reload.status, row.attention_reason]
  end

  # --- the discussion fix, same seam ---------------------------------------

  def test_the_discussion_fix_is_bounded_too
    row = fixing_issue
    (threshold - 1).times { fix(row) }

    assert_equal 'fixing_discussions', row.reload.status

    fix(row)

    assert_equal %w[done gitlab_refused_request], [row.reload.status, row.attention_reason]
  end

  def test_the_discussion_fix_never_gives_up_on_an_outage
    row = fixing_issue
    (threshold * 3).times { fix(row, error: outage) }

    assert_equal 'fixing_discussions', row.reload.status
  end

  private

  # `threshold` refusals with one poll that refused nothing sitting in the middle
  # of them. The intermediate assertion is here rather than in the test so the
  # test reads as the one claim it makes.
  def refuse_across_a_healthy_poll(row)
    (threshold - 1).times { poll(row) }
    poll(row, outcome: :inconclusive)

    assert_equal 'checking_pipeline', row.reload.status, 'a poll with no refusal was counted as one'
    poll(row)
  end

  def watched_issue
    issue = Issue.create!(project_path: PROJECT_PATH, issue_iid: 15_205, mr_iid: 11_258,
                          mr_url: 'https://gitlab.example/mr/11258', issue_author_id: 42,
                          branch_name: 'autodev/issue-15205', status: 'checking_pipeline',
                          review_count: 0, locale: 'fr')
    issue.update(checking_pipeline_since: Time.current)
    issue
  end

  def fixing_issue
    Issue.create!(project_path: PROJECT_PATH, issue_iid: 15_206, mr_iid: 11_259,
                  mr_url: 'https://gitlab.example/mr/11259', issue_author_id: 42,
                  branch_name: 'autodev/issue-15206', status: 'fixing_discussions',
                  review_count: 1, locale: 'fr')
  end

  # One poll of a green pipeline whose review publishes — every step before the
  # publication is the real code, so the boundary that catches this is the real
  # one, and so is the round trip through `reviewing` that `resume_watch` makes.
  def poll(issue, error: nil, outcome: nil)
    failure = error || refusal
    client = StubClient.new
    mon = worker(PipelineMonitor, client)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:review_with_skill) { |_issue| outcome || raise(failure) }
    mon.check(issue)
    client
  end

  def fix(issue, error: nil)
    failure = error || refusal
    client = StubClient.new
    fixer = worker(MrFixer, client)
    fixer.define_singleton_method(:fetch_unresolved_discussions) { |_iid| raise failure }
    fixer.fix(issue)
    client
  end

  def worker(klass, client)
    klass.allocate.tap do |obj|
      obj.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: { 'path' => PROJECT_PATH, 'review_skill' => 'mr-review' },
                             logger: NullLogger.new, token: 'tok')
      %i[log log_error].each { |m| obj.define_singleton_method(m) { |*| nil } }
      obj.define_singleton_method(:apply_label_attention) { |*| nil }
      obj.define_singleton_method(:apply_label_done) { |*| nil }
    end
  end
end
# rubocop:enable Metrics/ClassLength
