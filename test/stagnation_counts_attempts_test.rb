# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Autodev #71 — the stagnation counter counts *attempts*, not polls.
#
# `check_stagnation_and_fix` wrote the signature before calling `clone_and_fix`,
# and the prompt-context read that Autodev #67 made raising sits underneath it
# (`dispatch_fix` → `fetch_fix_context` → `GitlabHelpers.fetch_full_context`,
# whose `client.issue` read raises `ApiUnavailableError`). So a **selective**
# GitLab outage — the issue endpoint erroring while the jobs and merge-request
# endpoints answer normally — advanced the counter on every cycle without a
# single correction being attempted. At `stagnation_threshold` cycles the ticket
# was given up: `done`, `needs_attention: stagnation_pipeline`,
# `label_attention`, handed back to its author, and a public comment announcing
# a pipeline stagnation that never happened.
#
# The method's own comment already said why this matters — "a cycle that never
# looked at the failure must not count towards stagnation, or an outage would
# burn the whole budget and give the ticket up" — about the Claude-quota return
# one line above. The counter write sat below it.
#
# The fix is the ordering `MrFixer` has always had: `discussion_stagnated?` is
# called from `finalize_success`, i.e. after the fix ran. So the second class
# below is the control that matters: a *real* stagnation — the same jobs
# failing, GitLab answering, the fix attempted and getting nowhere — must still
# be given up at the threshold. Moving a counter down is also how you disarm a
# protection.

# --- shared fixtures -------------------------------------------------------

module StagnationFixtures
  # Short on purpose: the arithmetic is the same at 5 (the default) and the runs
  # below go one cycle past the threshold, which is where the give-up lands.
  THRESHOLD = 3
  AUTHOR_ID = 42

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review',
                     'label_attention' => 'Development::StandBy',
                     'stagnation_threshold' => THRESHOLD }.freeze

  # One `script_failure` on a `test` job: `pre_triage` reads that as `:code`, so
  # the fix path is entered without a danger-claude evaluation.
  FAILED_JOBS = [{ 'id' => 1, 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
                   'allow_failure' => false, 'failure_reason' => 'script_failure' }].freeze

  # The clone's job entries, as `write_and_categorize_jobs` would return them.
  JOB_ENTRIES = [{ name: 'rspec', stage: 'test', log_path: 'tmp/ci_logs/rspec.log', category: :test }].freeze

  # Gitlab::Error::ResponseError builds its message from the real HTTP response;
  # this is the minimum surface it reads.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Everything the poll reads, with one endpoint switchable. `issue_down:` is the
  # selective outage: the merge request and the pipeline jobs answer, the issue
  # does not — which is the shape of a real GitLab incident (one endpoint, one
  # slow query, one 500) and the shape the counter could not tell from a
  # stagnation.
  class FakeClient
    GlIssue = Struct.new(:iid, :title, :description, :labels, :id)
    GlNote = Struct.new(:id, :body, :system, :author, :created_at)
    GlMr = Struct.new(:state, :head_pipeline)
    GlPipeline = Struct.new(:id, :status)

    class Paginated
      def initialize(items) = @items = items
      def auto_paginate = @items
    end

    attr_reader :notes, :edits, :issue_reads

    def initialize(issue_down:)
      @issue_down = issue_down
      @notes = []
      @edits = []
      @issue_reads = 0
    end

    def merge_request(_path, _iid)
      GlMr.new(state: 'opened', head_pipeline: GlPipeline.new(id: 215_229, status: 'failed'))
    end

    def pipeline_jobs(_path, _pid, **_opts) = StagnationFixtures::FAILED_JOBS

    # Only reached by the `:uncertain` triage, which retriggers once before it
    # evaluates anything.
    def retry_pipeline(_path, _pid) = nil

    def issue(_path, iid)
      @issue_reads += 1
      raise api_error if @issue_down

      GlIssue.new(iid: iid, title: 'Ticket', description: 'the body', labels: ['Development::Doing'], id: 1)
    end

    def issue_notes(_path, _iid, **_opts) = Paginated.new([])
    def issue_links(_path, _iid) = []
    def merge_request_discussions(_path, _iid, **_opts) = Paginated.new([])
    def user = GlIssue.new(id: 999, labels: [])

    def edit_issue(_path, iid, **attrs)
      @edits << [iid, attrs]
      GlIssue.new(iid: iid, labels: [], id: 1)
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      GlNote.new(id: @notes.size, body: body, system: false)
    end

    def issue_note(_path, _iid, note_id) = GlNote.new(id: note_id, body: @notes.last.to_s)

    def edit_issue_note(_path, _iid, _note_id, body)
      @notes[-1] = body
      GlNote.new(id: 1, body: body, system: false)
    end

    private

    def api_error
      Gitlab::Error::ResponseError.new(
        StagnationFixtures::FakeResponse.new('boom', 500,
                                             StagnationFixtures::FakeRequest.new('https://gitlab.example',
                                                                                 '/api/v4/issues'))
      )
    end
  end

  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  # `check` is driven for real, end to end. What is stubbed is only what leaves
  # the process for something other than GitLab: the clone, the log files, the
  # danger-claude calls and the push. `dispatch_fix` itself — and with it
  # `fetch_fix_context`, the read this ticket is about — runs.
  def monitor(client)
    PipelineMonitor.allocate.tap do |mon|
      mon.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: PROJECT_CONFIG, logger: NullLogger.new, token: 'tok')
      stub_local_work(mon)
    end
  end

  def stub_local_work(mon)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:prepare_work_dir) { |*| nil }
    mon.define_singleton_method(:write_and_categorize_jobs) { |*| StagnationFixtures::JOB_ENTRIES.map(&:dup) }
    mon.define_singleton_method(:fix_each_job) { |*| nil }
    # The real `push_fixes`'s no-new-commits branch: a fix that produced nothing
    # still ends its round and returns to `checking_pipeline`, which is exactly
    # the cycle a genuine stagnation repeats.
    mon.define_singleton_method(:push_fixes) do |_work_dir, job_entries, issue|
      send(:complete_fix_round, issue, job_entries, pushed: false)
    end
  end

  def watched_issue
    issue = create_issue(mr_iid: 7, mr_url: 'http://gitlab/mr/7', issue_author_id: AUTHOR_ID,
                         branch_name: 'autodev/71', locale: 'fr')
    advance_to(issue, 'checking_pipeline')
    issue
  end

  # `cycles` consecutive polls on the same failing job set, as
  # `dispatch_pipelines` would.
  def poll_cycles(issue_down:, cycles: THRESHOLD + 1)
    client = FakeClient.new(issue_down: issue_down)
    mon = monitor(client)
    issue = watched_issue
    cycles.times { mon.check(issue.reload) }
    [issue.reload, client]
  end

  def stagnation_count(issue)
    JSON.parse(issue.stagnation_signatures || '{}').dig('pipeline', 'count')
  end
end

# --- 1. the bug: a cycle that concluded nothing must not spend the budget ---

class StagnationOutageTest < Minitest::Test
  include DatabaseTestHelper
  include StagnationFixtures

  def setup = setup_database

  def test_a_selective_outage_does_not_advance_the_stagnation_counter
    issue, = poll_cycles(issue_down: true)

    assert_nil stagnation_count(issue),
               'a cycle that never reached the correction counted towards stagnation'
  end

  def test_a_selective_outage_does_not_give_the_ticket_up
    issue, = poll_cycles(issue_down: true)

    assert_equal ['checking_pipeline', false, nil],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  def test_a_selective_outage_announces_no_stagnation
    _issue, client = poll_cycles(issue_down: true)

    refute(client.notes.any? { |body| body.to_s.include?('stagnation') },
           'a pipeline stagnation that never happened was announced on the ticket')
    assert_empty client.edits, 'no end label and no handback may follow a poll that read nothing'
  end

  # The read is attempted on every cycle: the row stays in the pass's population
  # and recovers on its own when GitLab does.
  def test_the_outage_is_re_read_on_every_cycle
    _issue, client = poll_cycles(issue_down: true)

    assert_equal THRESHOLD + 1, client.issue_reads
  end

  # The other cycle that concludes nothing: an evaluation that could not be
  # performed (danger-claude crashed, timed out, or answered something
  # unparseable) already stands the age bound down via `poll_inconclusive!`
  # (Autodev #56/#62). It read the failure and got no answer, so it must not
  # spend a stagnation cycle either — otherwise a Docker outage announces a
  # pipeline stagnation the same way a GitLab one did.
  def test_an_evaluation_that_never_ran_does_not_advance_the_counter
    issue, client = uncertain_poll_cycles(eval_result: nil)

    assert_nil stagnation_count(issue)
    assert_equal 'checking_pipeline', issue.status
    refute(client.notes.any? { |body| body.to_s.include?('stagnation') })
  end

  # One cycle longer than the `:code` runs: an `:uncertain` verdict spends the
  # first poll retriggering the pipeline (`retrigger_if_needed`), which
  # deliberately counts towards nothing.
  def uncertain_poll_cycles(eval_result:, cycles: THRESHOLD + 2)
    client = FakeClient.new(issue_down: false)
    mon = monitor(client)
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :uncertain, explanation: nil } }
    mon.define_singleton_method(:evaluate_code_related) { |*| eval_result }
    issue = watched_issue
    cycles.times { mon.check(issue.reload) }
    [issue.reload, client]
  end
end

# --- 2. the control: the protection is still armed -------------------------

class StagnationStillGivesUpTest < Minitest::Test
  include DatabaseTestHelper
  include StagnationFixtures

  def setup = setup_database

  def test_a_real_stagnation_still_gives_the_ticket_up
    issue, = poll_cycles(issue_down: false)

    assert_equal ['done', true, 'stagnation_pipeline'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
  end

  def test_a_real_stagnation_counts_one_cycle_per_attempted_fix
    issue, = poll_cycles(issue_down: false, cycles: THRESHOLD)

    assert_equal THRESHOLD, stagnation_count(issue)
    assert_equal 'checking_pipeline', issue.status, 'the give-up lands on the cycle after the threshold'
  end

  def test_a_real_stagnation_says_so_on_the_ticket
    _issue, client = poll_cycles(issue_down: false)

    assert(client.notes.any? { |body| body.to_s.include?('rspec') },
           'the stagnation comment must name the failing job')
  end

  # "The failure is not code-related" IS a verdict — the poll read one and
  # decided to wait — so it counts, and a wait that repeats is a stagnation.
  def test_a_non_code_verdict_still_advances_the_counter
    client = FakeClient.new(issue_down: false)
    mon = monitor(client)
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :uncertain, explanation: nil } }
    mon.define_singleton_method(:evaluate_code_related) do |*|
      { 'code_related' => false, 'explanation' => 'runner died' }
    end
    issue = watched_issue
    (THRESHOLD + 2).times { mon.check(issue.reload) }

    assert_equal ['done', true, 'stagnation_pipeline'],
                 [issue.reload.status, issue.needs_attention, issue.attention_reason]
  end
end
