# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/mr_fixer'

# Autodev #121 — a functional divergence found in review becomes a question on
# the ticket, and the answer resumes the same merge request.
#
# Replayed case: powerpanne/core#14746 (A#111, MR !11409). The review opened
# « Divergence fonctionnelle (à valider par le PO) » threads; `MrFixer` treated
# them as code to correct for four rounds (29/08/2026, 04:54 → 14:47), producing
# nothing but "UI différée en attente d'arbitrage PO" comments, and the request
# was abandoned on an unrelated stagnation. The requester was never asked.
module FunctionalDivergenceFixtures
  PATH = 'modulosource/powerpanne/powerpanne/core'
  AUTHOR = 'alves_b'
  PROJECT_CONFIG = { 'path' => PATH, 'labels_todo' => ['To do', 'Development::ToDo'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review',
                     'label_attention' => 'Development::StandBy',
                     'stagnation_threshold' => 5 }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  Author = Struct.new(:name, :username)
  Note = Struct.new(:body, :author, :created_at, :system)
  GlIssue = Struct.new(:iid, :title, :created_at, :author)
  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  GAP = "**Divergence fonctionnelle — livraison automatique mensuelle vs. UI de sélection de période**\n\n" \
        'Le demandeur a répondu « 3. (b) Une interface utilisateur permettant de choisir une période ».'

  class Client
    attr_reader :posted
    attr_accessor :fail_post, :mr_state

    def initialize(notes: [], mr_state: 'opened')
      @notes = notes
      @mr_state = mr_state
      @posted = []
    end

    def merge_request(_path, _iid) = Struct.new(:state).new(mr_state)

    def issue(_path, iid) = GlIssue.new(iid, 'Export Excel RAD', nil, Author.new('Bryan Alves', AUTHOR))

    def create_issue_note(_path, iid, body)
      raise fail_post if fail_post

      @posted << [iid, body]
      Struct.new(:id).new(1)
    end

    def issue_notes(_path, _iid, **_opts) = Paginated.new(@notes)
    def edit_issue_note(*) = nil
  end

  def functional_thread(id = 'f-1')
    body = "#{ReviewPublisher::FUNCTIONAL_MARKER}\n" \
           "#{Locales.t(:review_functional_finding_label, locale: :fr, tag: '**autodev**')}\n\n#{GAP}"
    { id: id, title: body[0, 80], notes: [Note.new(body: body, author: Author.new('autodev', 'autodev'),
                                                   created_at: '2026-08-29T02:00:00Z', system: false)] }
  end

  def code_thread(id = 'c-1')
    body = '**`find_each` ignore silencieusement le `.order(:invoiced_at)`**'
    { id: id, title: body, notes: [Note.new(body: body, author: Author.new('autodev', 'autodev'),
                                            created_at: '2026-08-29T02:00:00Z', system: false)] }
  end

  def human_note(body, at)
    Note.new(body: body, author: Author.new('Bryan Alves', AUTHOR), created_at: at, system: false)
  end

  def fixing_issue(**overrides)
    create_issue({ project_path: PATH, issue_iid: 14_746, mr_iid: 11_409, status: 'fixing_discussions',
                   branch_name: 'autodev/14746', review_count: 1, fix_round: 3, discussion_fix_round: 2,
                   stagnation_signatures: '{"discussions":{"sig":"abc","count":1}}' }.merge(overrides))
  end
end

class AFunctionalDivergenceAsksTheRequesterTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper
  include FunctionalDivergenceFixtures

  def setup
    setup_database
    @sink = { activity: [], cycles: [], labels: [] }
  end

  def fixer(client)
    MrFixer.allocate.tap do |fix|
      fix.instance_variable_set(:@client, client)
      fix.instance_variable_set(:@project_config, PROJECT_CONFIG)
      fix.instance_variable_set(:@config, CONFIG)
      fix.instance_variable_set(:@project_path, PATH)
      stub(fix)
    end
  end

  def stub(fix)
    sink = @sink
    %i[log log_error].each { |noop| fix.define_singleton_method(noop) { |*| nil } }
    fix.define_singleton_method(:log_activity) { |_i, key, **vars| sink[:activity] << [key, vars] }
    stub_cycle_and_labels(fix)
  end

  def stub_cycle_and_labels(fix)
    sink = @sink
    # Writes the counter the real cycle writes, so a round that reached it
    # cannot pass for one that did not.
    fix.define_singleton_method(:execute_fix_cycle) do |i, discussions|
      sink[:cycles] << discussions
      i.update(discussion_fix_round: i.discussion_fix_round + 1)
    end
    fix.define_singleton_method(:apply_label_todo) { |iid| sink[:labels] << [:todo, iid] }
    fix.define_singleton_method(:apply_label_doing) { |iid, **| sink[:labels] << [:doing, iid] }
  end

  def run_round(client, issue, discussions)
    DiscussionSnapshot.stub(:capture, nil) { fixer(client).send(:process_discussions, issue, discussions) }
  end

  # === The ticket's first proof: the PowerPanne case ===

  def asked(client = Client.new, issue = fixing_issue)
    run_round(client, issue, [functional_thread])
    client.posted
  end

  def test_a_functional_divergence_becomes_one_question_on_the_ticket
    posted = asked

    assert_equal [14_746], posted.map(&:first), 'one question, on the ticket'
    assert_includes posted.first.last, "@#{AUTHOR}", 'addressed to the requester'
    assert_includes posted.first.last, '!11409', 'names what was delivered'
  end

  def test_the_question_states_the_gap_as_the_review_wrote_it
    body = asked.first.last

    assert_includes body, 'livraison automatique mensuelle vs. UI de sélection', 'states the gap'
    refute_includes body, ReviewPublisher::FUNCTIONAL_MARKER
    refute_includes body, 'ne tranchera pas ce point seul', 'the review label is not the question'
  end

  def test_the_row_waits_in_needs_clarification_and_no_correction_runs
    issue = fixing_issue
    asked(Client.new, issue)

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty @sink[:cycles], 'not a second round of correction'
    refute_nil issue.clarification_requested_at
  end

  def test_the_wait_records_where_the_answer_goes_and_what_was_asked
    issue = fixing_issue
    asked(Client.new, issue)
    issue.reload

    assert_equal Issue::RESUME_TO_FIXING, issue.clarification_resume_to
    assert_equal ['f-1'], JSON.parse(issue.functional_questions).keys
  end

  def test_the_wait_is_visible_and_discoverable
    asked

    assert_includes @sink[:labels], [:todo, 14_746], 'the entry label keeps the row discoverable (#75)'
    assert_includes @sink[:activity].map(&:first), :functional_question_asked
  end

  # Owner: these rounds count toward neither stagnation_discussions nor
  # fix_rounds_exhausted.
  def test_the_question_round_counts_toward_nothing
    issue = fixing_issue

    run_round(Client.new, issue, [functional_thread])
    issue.reload

    assert_equal [3, 2], [issue.fix_round, issue.discussion_fix_round]
    assert_equal '{"discussions":{"sig":"abc","count":1}}', issue.stagnation_signatures
  end

  # The code threads wait for the answer: the decision may change the code they
  # are about.
  def test_a_round_mixing_both_asks_and_fixes_nothing
    client = Client.new
    issue = fixing_issue

    run_round(client, issue, [code_thread, functional_thread])

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty @sink[:cycles]
    assert_equal ['f-1'], JSON.parse(issue.functional_questions).keys
  end

  # === The ticket's third proof: a real code discussion is not diverted ===

  def test_a_code_discussion_is_fixed_not_asked
    client = Client.new
    issue = fixing_issue

    run_round(client, issue, [code_thread])

    assert_empty client.posted
    assert_equal([['c-1']], @sink[:cycles].map { |ds| ds.map { |d| d[:id] } })
    assert_equal 'fixing_discussions', issue.reload.status
  end

  # A thread whose first note merely *quotes* the words is not functional: the
  # signal is the marker autodev posts, never the prose.
  def test_the_words_alone_are_not_the_signal
    client = Client.new
    thread = code_thread.merge(notes: [human_note('Divergence fonctionnelle (à valider par le PO)', '2026-08-29')])

    run_round(client, fixing_issue, [thread])

    assert_empty client.posted
    assert_equal 1, @sink[:cycles].size
  end

  # === A question that could not be posted parks nothing ===

  def test_an_unposted_question_leaves_the_row_where_it_was # rubocop:disable Minitest/MultipleAssertions
    client = Client.new
    client.fail_post = Errno::ECONNRESET
    issue = fixing_issue

    assert_raises(ApiUnavailableError) { run_round(client, issue, [functional_thread]) }
    issue.reload

    assert_equal 'fixing_discussions', issue.status
    assert_nil issue.functional_questions
    assert_nil issue.clarification_resume_to
    assert_nil issue.clarification_requested_at
  end

  # Through the real boundary: the round ends there, the next cycle asks again.
  def test_the_fix_boundary_absorbs_the_outage
    client = Client.new
    client.fail_post = Errno::ECONNRESET
    issue = fixing_issue
    fix = fixer(client)
    thread = functional_thread
    fix.define_singleton_method(:fetch_unresolved_discussions) { |*| [:raw] }
    fix.define_singleton_method(:build_discussion) { |*| thread }

    DiscussionSnapshot.stub(:capture, nil) { fix.fix(issue) }

    assert_equal 'fixing_discussions', issue.reload.status
  end

  # === After the answer ===

  def answered_round(thread = functional_thread)
    client = Client.new(notes: [human_note('Avant la question', '2026-08-29T09:00:00Z'),
                                human_note('**autodev** (v1) : la question elle-même', '2026-08-29T10:00:01Z'),
                                Note.new('a changé la description', nil, '2026-08-29T11:00:00Z', true),
                                human_note('Il faut une UI de sélection de période (1 mois max).',
                                           '2026-08-30T08:00:00Z')])
    issue = fixing_issue(functional_questions: JSON.generate('f-1' => '2026-08-29T10:00:00Z'))
    fix = fixer(client)
    DiscussionSnapshot.stub(:capture, nil) { fix.send(:process_discussions, issue, [thread]) }
    [client, fix]
  end

  def test_an_asked_thread_is_fixed_and_not_asked_again
    client, = answered_round

    assert_empty client.posted, 'never asked twice'
    assert_equal 1, @sink[:cycles].size
  end

  def test_the_fix_context_quotes_the_answer_given_after_the_question
    _, fix = answered_round
    section = fix.send(:functional_answer_section, functional_thread)

    assert_includes section, 'Il faut une UI de sélection de période'
    refute_includes section, 'Avant la question', 'only what was said after the question'
  end

  def test_the_fix_context_quotes_neither_autodev_nor_gitlab
    _, fix = answered_round
    section = fix.send(:functional_answer_section, functional_thread)

    refute_includes section, 'la question elle-même'
    refute_includes section, 'a changé la description'
  end

  def test_a_code_thread_carries_no_answer_section
    issue = fixing_issue(functional_questions: JSON.generate('f-1' => '2026-08-29T10:00:00Z'))
    fix = fixer(Client.new(notes: [human_note('Réponse', '2026-08-30T08:00:00Z')]))

    DiscussionSnapshot.stub(:capture, nil) { fix.send(:process_discussions, issue, [code_thread]) }

    assert_equal '', fix.send(:functional_answer_section, code_thread)
  end

  # The first round after the resume puts the ticket back on the doing label and
  # spends the destination, so it is reposed once and not on every round.
  def test_the_first_resumed_round_reposes_the_doing_label_once
    issue = fixing_issue(clarification_resume_to: Issue::RESUME_TO_FIXING,
                         functional_questions: JSON.generate('f-1' => '2026-08-29T10:00:00Z'))

    run_round(Client.new, issue, [functional_thread])
    run_round(Client.new, issue.reload, [functional_thread])

    assert_equal [[:doing, 14_746]], @sink[:labels]
    assert_nil issue.reload.clarification_resume_to
  end

  def test_the_question_names_the_gitlab_username_not_the_display_name
    body = asked(Client.new, fixing_issue(issue_author_name: 'Bryan Alves')).first.last

    assert_includes body, "@#{AUTHOR} "
    refute_includes body, '@Bryan'
  end

  def test_the_question_is_in_the_requests_locale
    body = asked(Client.new, fixing_issue(locale: 'en')).first.last

    assert_includes body, 'implements this ticket'
    refute_includes body, '%{', 'every placeholder is filled'
  end

  def test_a_mixed_round_asks_only_about_the_functional_gap
    client = Client.new
    run_round(client, fixing_issue, [code_thread, functional_thread])

    refute_includes client.posted.first.last, 'find_each'
  end

  # Only the FIRST note is the review's: a human reply quoting autodev's marker
  # does not turn a code thread into a question.
  def test_a_marker_in_a_reply_is_not_the_signal
    client = Client.new
    quoted = human_note("> #{ReviewPublisher::FUNCTIONAL_MARKER} cité", '2026-08-30')
    thread = code_thread.merge(notes: code_thread[:notes] + [quoted])

    run_round(client, fixing_issue, [thread])

    assert_empty client.posted
    assert_equal 1, @sink[:cycles].size
  end

  # Through the database: the second round is a new job, a new object and a
  # fresh read of the row.
  def test_a_reloaded_row_is_never_asked_twice
    client = Client.new
    issue = fixing_issue
    run_round(client, issue, [functional_thread])
    back_to_fixing(issue)

    run_round(client, Issue.find(issue.id), [functional_thread])

    assert_equal 1, client.posted.size, 'asked once'
    assert_equal 1, @sink[:cycles].size
  end

  def test_an_http_refusal_of_the_question_parks_nothing_either
    client = Client.new
    client.fail_post = Gitlab::Error::InternalServerError.new(
      Struct.new(:parsed_response, :code, :request).new('boom', 500, Struct.new(:base_uri, :path).new('h', '/x'))
    )
    issue = fixing_issue

    assert_raises(ApiUnavailableError) { run_round(client, issue, [functional_thread]) }
    assert_equal 'fixing_discussions', issue.reload.status
    assert_empty @sink[:labels], 'no entry label for a question nobody can read'
  end

  # One `save!` for the status and what the wait needs, so the #97 refusal
  # covers both: a row a human closed meanwhile gets neither.
  def test_a_row_moved_meanwhile_gets_no_wait_columns
    issue = fixing_issue
    Issue.where(id: issue.id).update_all(status: 'closed')

    assert_raises(StaleTransitionError) { run_round(Client.new, issue, [functional_thread]) }
    row = Issue.find(issue.id)

    assert_equal 'closed', row.status
    assert_nil row.clarification_resume_to
  end

  def asked_ids(issue) = Issue.parse_functional_questions(Issue.find(issue.id).functional_questions).keys.sort

  def reset_then_fix(issue)
    Issue.reset_for_retry!(Issue.where(id: issue.id), reset_budget: true, clear_attention: true)
    back_to_fixing(issue)
  end

  def back_to_fixing(issue)
    Issue.where(id: issue.id).update_all(status: 'fixing_discussions', clarification_resume_to: nil)
  end

  # GitLab answered that the note cannot be created as formed (400/422): an
  # `InvalidRequestError`, which still parks nothing.
  def test_a_refused_question_parks_nothing
    client = Client.new
    client.fail_post = Gitlab::Error::BadRequest.new(
      Struct.new(:parsed_response, :code, :request).new('bad', 400, Struct.new(:base_uri, :path).new('h', '/x'))
    )
    issue = fixing_issue

    assert_raises(InvalidRequestError) { run_round(client, issue, [functional_thread]) }
    assert_equal 'fixing_discussions', issue.reload.status
  end

  # A second review round adds a new functional thread: the first stays asked.
  def test_a_second_question_keeps_the_first_on_record
    issue = fixing_issue
    run_round(Client.new, issue, [functional_thread('f-1')])
    back_to_fixing(issue)

    run_round(Client.new, Issue.find(issue.id), [functional_thread('f-1'), functional_thread('f-2')])

    assert_equal %w[f-1 f-2], asked_ids(issue)
  end

  # The wait lasted days: a merge request merged, closed or mid-merge meanwhile
  # is not fixed, the watch decides (adversarial review).
  %w[merged closed locked].each do |state|
    define_method("test_an_answer_after_the_merge_request_is_#{state}_goes_back_to_the_watch") do
      issue = fixing_issue(clarification_resume_to: Issue::RESUME_TO_FIXING,
                           functional_questions: JSON.generate('f-1' => '2026-08-29T10:00:00Z'))

      run_round(Client.new(mr_state: state), issue, [functional_thread])

      assert_equal ['checking_pipeline', []], [issue.reload.status, @sink[:cycles]]
    end
  end

  def test_an_ended_merge_request_gets_no_doing_label
    issue = fixing_issue(clarification_resume_to: Issue::RESUME_TO_FIXING)

    run_round(Client.new(mr_state: 'merged'), issue, [functional_thread])

    assert_empty @sink[:labels]
  end

  # An operator Reset of a row still waiting: the unanswered question is
  # forgotten and asked again, never fixed with no decision (review of the
  # branch). The question answered earlier stays answered.
  def test_a_reset_while_waiting_asks_again_instead_of_fixing
    client = Client.new
    issue = fixing_issue(functional_questions: JSON.generate('f-0' => '2026-08-01T10:00:00Z'))
    run_round(client, issue, [functional_thread('f-1')])
    reset_then_fix(issue)

    run_round(client, Issue.find(issue.id), [functional_thread('f-1')])

    assert_equal 2, client.posted.size, 'asked again'
    assert_equal %w[f-0 f-1], asked_ids(issue)
  end

  # A resumed row whose first round has not run yet has its answer: a Reset
  # then keeps what was asked.
  def test_a_reset_after_the_answer_keeps_the_question
    issue = fixing_issue(clarification_resume_to: Issue::RESUME_TO_FIXING,
                         functional_questions: JSON.generate('f-1' => '2026-08-29T10:00:00Z'))

    Issue.reset_for_retry!(Issue.where(id: issue.id), reset_budget: true)

    assert_equal ['f-1'], JSON.parse(Issue.find(issue.id).functional_questions).keys
  end

  # The skill is told what the field means — the field is the whole signal.
  def test_the_review_prompt_asks_for_the_category
    monitor = PipelineMonitor.allocate
    prompt = monitor.send(:review_prompt, Struct.new(:mr_iid).new(1), 'mr-review', '/tmp/x.json')

    assert_includes prompt, '"category":"code|functional"'
  end
end

# The ticket's second proof: the answer brings the row back on its merge request.
# ClassLength: the resume and every way it must not happen, over one dispatcher fixture.
class AFunctionalAnswerResumesTheMergeRequestTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper
  include FunctionalDivergenceFixtures

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def waiting_issue(**overrides)
    create_issue({ project_path: PATH, issue_iid: 14_746, mr_iid: 11_409, status: 'needs_clarification',
                   branch_name: 'autodev/14746', review_count: 1,
                   clarification_requested_at: Time.parse('2026-08-29T10:00:00Z'),
                   clarification_resume_to: Issue::RESUME_TO_FIXING,
                   functional_questions: JSON.generate('f-1' => '2026-08-29T10:00:00Z') }.merge(overrides))
  end

  def dispatcher(client)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, PATH)
      d.instance_variable_set(:@project_config, PROJECT_CONFIG)
      d.instance_variable_set(:@config, CONFIG)
      d.instance_variable_set(:@logger, @logger)
      d.instance_variable_set(:@token, 'x')
      d.instance_variable_set(:@client, client)
    end
  end

  def run_pass(issue, client)
    enqueued = []
    gl_issue = GlIssue.new(issue.issue_iid, 'title', nil, nil)
    GitlabHelpers.stub(:fetch_assignee_issues, [gl_issue]) do
      GitlabHelpers.stub(:current_user_id, 1) do
        IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
          dispatcher(client).send(:dispatch_new_issues)
        end
      end
    end
    enqueued
  end

  def answer = human_note('Il faut une UI de sélection de période.', '2026-08-30T08:00:00Z')

  def test_the_answer_resumes_fixing_discussions_on_the_same_merge_request # rubocop:disable Minitest/MultipleAssertions
    issue = waiting_issue

    enqueued = run_pass(issue, Client.new(notes: [answer]))
    issue.reload

    assert_equal 'fixing_discussions', issue.status, 'not pending: no re-implementation'
    assert_equal 11_409, issue.mr_iid
    assert_equal 'autodev/14746', issue.branch_name
    assert_empty enqueued, 'no :process job — dispatch_discussions picks the row up'
  end

  def test_no_answer_keeps_the_row_waiting
    issue = waiting_issue

    run_pass(issue, Client.new(notes: []))

    assert_equal 'needs_clarification', issue.reload.status
  end

  # A spec clarification keeps its destination.
  def test_a_spec_clarification_still_resumes_to_pending
    issue = waiting_issue(clarification_resume_to: nil, mr_iid: nil, functional_questions: nil)

    enqueued = run_pass(issue, Client.new(notes: [answer]))

    assert_equal 'pending', issue.reload.status
    assert_equal [[PATH, 14_746, :process]], enqueued
  end

  def test_the_guard_needs_the_merge_request
    issue = waiting_issue(mr_iid: nil)

    issue.clarification_received!

    assert_equal 'pending', issue.reload.status
  end

  def test_the_sweep_enqueues_nothing_for_a_row_resumed_on_its_merge_request
    issue = waiting_issue
    enqueued = []
    sweep = Autodev::ClarificationSweep.allocate
    sweep.instance_variable_set(:@out, StringIO.new)
    resumer = Autodev::ClarificationResume.new(client: Client.new, path: PATH, logger: @logger)

    IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) { sweep.send(:apply!, issue, resumer) }

    assert_equal 'fixing_discussions', issue.reload.status
    assert_empty enqueued
  end

  # autodev's own question sits on the ticket after the stamp; it must not
  # read as the requester's answer (`HumanActivity` reads `**autodev**`).
  def test_autodev_s_own_question_is_not_the_answer
    issue = create_issue(project_path: PATH, issue_iid: 14_746, mr_iid: 11_409, status: 'fixing_discussions',
                         branch_name: 'autodev/14746', review_count: 1)
    fix = MrFixer.allocate
    fix.instance_variable_set(:@project_path, PATH)
    body = fix.send(:functional_question_body, issue, [], GlIssue.new(1, 't', nil, nil))
    question = Note.new(body, nil, (Time.parse('2026-08-29T10:00:00Z') + 1).iso8601, false)

    run_pass(waiting_issue(issue_iid: 14_747), Client.new(notes: [question]))

    assert_equal 'needs_clarification', Issue.find_by(issue_iid: 14_747).status
  end

  def test_a_spec_clarification_on_a_row_with_a_merge_request_resumes_to_pending
    issue = waiting_issue(clarification_resume_to: nil)

    issue.clarification_received!

    assert_equal 'pending', issue.reload.status
  end

  def test_dispatch_discussions_picks_the_resumed_row_up
    issue = waiting_issue
    run_pass(issue, Client.new(notes: [answer]))
    enqueued = []

    IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
      dispatcher(Client.new).send(:dispatch_discussions)
    end

    assert_equal [[PATH, 14_746, :fix_discussions]], enqueued
  end

  # The #86 budget arm, unchanged for this population: a spent budget is
  # refused before any reply is read, and `ClarificationWatch` flags it.
  def test_a_spent_budget_still_refuses_the_resume
    issue = waiting_issue(retry_count: 99)

    run_pass(issue, Client.new(notes: [answer]))

    assert_equal 'needs_clarification', issue.reload.status
  end

  def test_the_dashboard_cannot_fire_the_question_by_hand
    host = Class.new { include ::Web::Helpers }.new
    issue = create_issue(project_path: PATH, issue_iid: 1, mr_iid: 2, status: 'fixing_discussions')

    refute_includes host.permitted_events_for(issue), :functional_question
  end

  # A re-entry ends the wait; `reenter` also forgets the questions, since it
  # rebuilds the branch they were asked about.
  def test_reenter_clears_both_columns
    issue = waiting_issue(status: 'done')

    issue.reenter!
    issue.reload

    assert_nil issue.clarification_resume_to
    assert_nil issue.functional_questions
  end

  def test_reenter_to_check_pipeline_keeps_the_questions
    issue = waiting_issue(status: 'done')

    issue.reenter_to_check_pipeline!
    issue.reload

    assert_nil issue.clarification_resume_to
    refute_nil issue.functional_questions
  end
end
