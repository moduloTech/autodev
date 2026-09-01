# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/mr_fixer'
require 'autodev/pipeline_monitor'
require 'autodev/issue_processor'

# Autodev #67 — the #62 rule applied to the read it had left uncovered.
#
# Autodev #62 established that a GitLab read whose answer a caller acts on must
# raise rather than substitute a value, and hoisted the two reads on the delivery
# path (`fetch_failed_jobs`, `fetch_unresolved_discussions`) out of the rescues
# that would have imputed their failure to the fix. One read was left underneath
# both of them: `GitlabHelpers.fetch_full_context` → `fetch_issue_context` →
# a bare `client.issue(...)`, the assembly of the danger-claude prompt.
#
# That read sits inside `attempt_fix` (pipeline) and `execute_fix_cycle` (MR), so
# a GitLab 500 while building a prompt was charged to the *correction*:
# `safe_mark_failed!` → `error`, a public comment saying the pipeline fix or the
# MR fix failed, and — on the pipeline side — a row parked in `error` that only
# the dormant audit ever looks at again. Nothing was wrong with the correction;
# GitLab hiccuped between reading the failed jobs and reading the ticket.
#
# What the two sections below pin is the outcome, not the mechanism: the row is
# left exactly where the poll found it, and nothing is announced. Each has its
# control — the same path with GitLab answering still fixes.
#
# Section 3 pins the deliberate *difference* on the third caller, the initial
# implementation path, where "conclude nothing and re-read next cycle" has no
# representation and `error` + a retry is the re-arming mechanism.
module PromptContextFixtures
  FakePipeline = Struct.new(:id, :status)
  # `target_branch` since Autodev #91: `run_fix_cycle` asks GitLab which branch
  # this merge request targets before it rebases anything.
  FakeMr = Struct.new(:state, :head_pipeline, :target_branch)
  # `author` / `created_at` / `position` are what `DiscussionFormatter` reads
  # when the same thread list is re-rendered into the prompt context.
  FakeNote = Struct.new(:resolvable, :resolved, :body, :author, :created_at, :position)
  FakeDiscussion = Struct.new(:id, :notes)
  FakeIssuePayload = Struct.new(:iid, :title, :description, :state)

  # `Gitlab::Error::ResponseError` builds its message from the real HTTP
  # response; this is the minimum surface it reads. Same fixture as
  # `test/api_failure_is_not_a_verdict_test.rb` — duplicated rather than shared
  # because every test file here has to pass run on its own (Autodev #64).
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  def api_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  # Behaves like Gitlab::PaginatedResponse.
  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
  end
end

# --- 1. the pipeline fix ---------------------------------------------------

# A red pipeline whose failed-job list read fine: the poll has a verdict and is
# entitled to act on it. It clones, categorises the jobs, and then asks GitLab
# for the ticket to build the prompt. That last read is the one under test.
class PipelineFixPromptContextTest < Minitest::Test
  include PromptContextFixtures
  include DatabaseTestHelper

  CODE_JOBS = [{ 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
                 'allow_failure' => false, 'failure_reason' => 'script_failure' }].freeze

  class StubClient
    attr_reader :issue_calls

    def initialize(error: nil)
      @error = error
      @issue_calls = 0
    end

    def merge_request(_path, _iid)
      PromptContextFixtures::FakeMr.new('opened', PromptContextFixtures::FakePipeline.new(9, 'failed'))
    end

    def pipeline_jobs(_path, _pid, **_opts) = CODE_JOBS

    def issue(_path, iid)
      @issue_calls += 1
      raise @error if @error

      PromptContextFixtures::FakeIssuePayload.new(iid, 'Le formulaire refuse les accents', 'body', 'opened')
    end

    def issue_notes(_path, _iid, **_opts) = PromptContextFixtures::FakePaginated.new([])
    def issue_links(_path, _iid) = []

    def merge_request_discussions(_path, _iid, **_opts)
      PromptContextFixtures::FakePaginated.new([])
    end
  end

  def setup
    setup_database
    @sink = { notify: [], activity: [], labels: [] }
  end

  # A whole `check` on a row whose pipeline is red for a code reason. Stubbed:
  # the clone, the job-log writing, the pre-triage verdict and the per-job
  # danger-claude calls. Real: the state machine, the AR row, the context read.
  def poll(error: nil)
    issue = create_issue(status: 'pending', mr_iid: 42, mr_url: 'http://gitlab/mr/42',
                         branch_name: 'autodev/1', issue_author_id: 7, review_count: 1)
    advance_to(issue, 'checking_pipeline')
    client = StubClient.new(error: error)
    monitor(client).check(issue)
    [issue.reload, @sink, client]
  end

  def monitor(client)
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, client)
    mon.instance_variable_set(:@project_path, 'group/project')
    mon.instance_variable_set(:@project_config, {})
    mon.instance_variable_set(:@config, {})
    %i[log log_error].each { |noop| mon.define_singleton_method(noop) { |*| nil } }
    stub_fix_path(mon)
    stub_sinks(mon)
    mon
  end

  def stub_fix_path(mon)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :code, explanation: 'rspec is red' } }
    mon.define_singleton_method(:prepare_work_dir) { |*| nil }
    mon.define_singleton_method(:write_and_categorize_jobs) do |*|
      [{ name: 'rspec', category: :test, log_path: '/tmp/rspec.log' }]
    end
    mon.define_singleton_method(:fix_each_job) { |*| nil }
    mon.define_singleton_method(:push_fixes) { |*| nil }
  end

  def stub_sinks(mon)
    sink = @sink
    mon.define_singleton_method(:log_activity) { |_i, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:apply_label_done) { |iid| sink[:labels] << iid }
    mon.define_singleton_method(:reassign_to_author) { |*| nil }
  end

  # The bug: the ticket read failed, and the correction was blamed for it.
  def test_an_unreadable_prompt_context_does_not_fail_the_ticket
    issue, sink = poll(error: api_error)

    refute_equal 'error', issue.status, 'a GitLab error on the prompt-context read is not a fix failure'
    assert_nil issue.error_message
    refute_includes sink[:notify].map(&:first), :pipeline_fix_error,
                    'no comment may accuse the correction of a failure GitLab caused'
  end

  # And it is left where `dispatch_pipelines` will find it again: parking it in
  # `fixing_pipeline` would be no better than `error`, since no pass selects that
  # state — only the dormant audit, two hours later.
  def test_an_unreadable_prompt_context_leaves_the_row_on_the_pipeline_watch
    issue, = poll(error: api_error)

    assert_equal 'checking_pipeline', issue.status
  end

  # Control: GitLab answering still reaches the fix.
  def test_a_readable_prompt_context_still_dispatches_the_fix
    issue, _sink, client = poll

    assert_equal 'fixing_pipeline', issue.status
    assert_equal 1, client.issue_calls, 'the prompt context must be read, not assumed'
  end
end

# --- 2. the MR discussion fix ---------------------------------------------

# `MrFixer#fix` reads the unresolved threads at its own boundary (Autodev #62),
# then `execute_fix_cycle` clones and calls `prepare_fix_environment`, which
# builds the prompt — and reads the ticket to do it.
class MrFixPromptContextTest < Minitest::Test
  include PromptContextFixtures
  include DatabaseTestHelper

  class StubClient
    attr_reader :issue_calls

    def initialize(error: nil)
      @error = error
      @issue_calls = 0
    end

    def merge_request_discussions(_path, _iid, **_opts)
      PromptContextFixtures::FakePaginated.new(
        [PromptContextFixtures::FakeDiscussion.new(
          'open-thread', [PromptContextFixtures::FakeNote.new(true, false, 'please fix this')]
        )]
      )
    end

    def issue(_path, iid)
      @issue_calls += 1
      raise @error if @error

      PromptContextFixtures::FakeIssuePayload.new(iid, 'Le formulaire refuse les accents', 'body', 'opened')
    end

    def issue_notes(_path, _iid, **_opts) = PromptContextFixtures::FakePaginated.new([])
    def issue_links(_path, _iid) = []

    # The target read of Autodev #91. It answers here: this file is about the
    # *prompt-context* read failing, and the two must not be conflated.
    def merge_request(_path, _iid) = PromptContextFixtures::FakeMr.new('opened', nil, 'main')
  end

  def setup
    setup_database
    @sink = { notify: [], activity: [] }
  end

  def run_fix(error: nil)
    issue = create_issue(status: 'pending', mr_iid: 42, mr_url: 'http://gitlab/mr/42',
                         branch_name: 'autodev/2', review_count: 1)
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!
    client = StubClient.new(error: error)
    SkillsInjector.stub(:inject, { all_skills: [] }) { fixer(client).fix(issue) }
    [issue.reload, @sink, client]
  end

  def fixer(client)
    MrFixer.allocate.tap do |fix|
      fix.instance_variable_set(:@client, client)
      fix.instance_variable_set(:@project_path, 'group/project')
      fix.instance_variable_set(:@project_config, {})
      fix.instance_variable_set(:@config, {})
      fix.instance_variable_set(:@logger, StubLogger.new)
      %i[log log_error].each { |noop| fix.define_singleton_method(noop) { |*| nil } }
      stub_cycle(fix)
      stub_sinks(fix)
    end
  end

  # Stubbed: the clone, the rebase, the git questions and the per-thread
  # danger-claude calls. Real: `prepare_fix_environment` and the read inside it.
  def stub_cycle(fix)
    fix.define_singleton_method(:clone_and_checkout) { |*| nil }
    fix.define_singleton_method(:rebase_branch_on_target) { |*| nil }
    fix.define_singleton_method(:default_branch) { |*| 'main' }
    fix.define_singleton_method(:detect_agent) { |*| nil }
    fix.define_singleton_method(:fix_each_discussion) { |*| nil }
    fix.define_singleton_method(:new_commits?) { |*| false }
  end

  def stub_sinks(fix)
    sink = @sink
    fix.define_singleton_method(:log_activity) { |_i, key, **vars| sink[:activity] << [key, vars] }
    fix.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
  end

  def test_an_unreadable_prompt_context_does_not_fail_the_ticket
    issue, sink = run_fix(error: api_error)

    refute_equal 'error', issue.status
    assert_nil issue.error_message
    refute_includes sink[:notify].map(&:first), :mr_fix_error,
                    'no comment may accuse the MR fix of a failure GitLab caused'
  end

  # `dispatch_discussions` re-enqueues `fixing_discussions` rows every cycle, so
  # staying put is the whole recovery.
  def test_an_unreadable_prompt_context_leaves_the_row_in_the_fix_round
    issue, = run_fix(error: api_error)

    assert_equal 'fixing_discussions', issue.status
  end

  # Control: GitLab answering still runs the round to its end.
  def test_a_readable_prompt_context_still_runs_the_round
    issue, _sink, client = run_fix

    assert_equal 'checking_pipeline', issue.status
    assert_equal 1, client.issue_calls
  end
end

# --- 3. the third caller: the initial implementation ----------------------

# `IssueProcessor#run_implementation` calls the same helper, and this is the one
# place the #62 answer does NOT transfer. The arbitration is pinned here so it
# cannot be mistaken for an oversight:
#
# a poll can conclude nothing and re-read next cycle because `dispatch_pipelines`
# and `dispatch_discussions` re-enqueue their whole population every cycle. An
# initial implementation has no such pass. The row is mid-flight in an active
# state, the clone is on disk, `label_doing` is posed and autodev is assigned;
# nothing re-enqueues an active row until `dispatch_dormant_audit` notices it two
# hours later. `error` + `next_retry_at` *is* the re-arming mechanism here
# (`dispatch_retries` → `:retry_stuck`/`:retry_errored`), it is bounded, and it
# is reversible. It is also not a misattribution: the comment this path posts is
# `error_generic`, which names the error class rather than blaming a correction.
#
# So `ApiUnavailableError` is deliberately left inside `handle_process_error`'s
# reach. What changes is only the exception's class, and that must not change who
# catches it.
class InitialImplementationPromptContextTest < Minitest::Test
  include PromptContextFixtures
  include DatabaseTestHelper

  class StubClient
    def initialize(error:) = @error = error
    def issue(_path, _iid) = raise(@error)
    def edit_issue(_path, _iid, **_opts) = nil
    def create_issue_note(_path, _iid, _body) = Struct.new(:id).new(1)
  end

  def setup = setup_database

  def test_the_prompt_context_read_raises_api_unavailable_error
    err = assert_raises(ApiUnavailableError) do
      GitlabHelpers.fetch_full_context(StubClient.new(error: api_error), 'group/project', 1)
    end

    assert_equal :issue, err.what
  end

  # The pin: an `ApiUnavailableError` on this path still ends in `error` with a
  # retry stamped, exactly as the `Gitlab::Error::ResponseError` did before.
  def test_an_unreachable_gitlab_still_parks_the_initial_implementation_for_retry
    issue = create_issue(status: 'pending')
    processor.process(issue)

    issue.reload

    assert_equal 'error', issue.status
    refute_nil issue.next_retry_at, 'the row must re-arm itself: nothing else re-enqueues an active state'
  end

  private

  # The read that fails first on this path is `issue_closed?`'s own bare
  # `@client.issue`, one call before `run_implementation` — which is why the
  # outcome is the same whichever of the two raises, and why the class of the
  # exception is all that #67 changes here.
  def processor
    IssueProcessor.allocate.tap do |proc_|
      { client: StubClient.new(error: api_error), project_path: 'group/project',
        project_config: {}, config: {}, logger: StubLogger.new }
        .each { |name, value| proc_.instance_variable_set(:"@#{name}", value) }
      %i[log log_error].each { |noop| proc_.define_singleton_method(noop) { |*| nil } }
      proc_.define_singleton_method(:log_activity) { |*, **| nil }
      proc_.define_singleton_method(:notify_localized) { |*, **| nil }
      proc_.define_singleton_method(:apply_label_doing) { |*| nil }
    end
  end
end
