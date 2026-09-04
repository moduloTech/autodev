# frozen_string_literal: true

require_relative '../rails_helper'

# This file used to define top-level stand-ins for the collaborators the job
# reaches (`Config`, `Issue`, `GitlabHelpers`, the three workflow classes,
# `ActivityLogger`), guarded by `unless defined?`, because AUTODEV_SKIP_LEGACY
# kept `lib/autodev` out of the AR test world. Since Autodev #64 the whole tree
# is required at boot, so every one of those guards was false and the stubs were
# never installed: the tests below exercise the real constants and stub the
# calls they make, one by one, with `.stub`. Nothing here needs to define them.
#
# Wiring test for IssueProcessJob — verifies each :action symbol routes to
# the right legacy worker without going through GitLab or Sequel for real.
# The job's value is the dispatch table; the per-action workers themselves
# are already covered by their own existing tests.
class IssueProcessJobTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  PROJECT_PATH = 'group/foo'
  ISSUE_IID = 42

  # The row state `Autodev::PollDispatcher` dispatches each action *from*,
  # written out literally rather than read off the production constant — the
  # point of the stale-job tests below is that the two agree, so a test that
  # derived one from the other would pass whatever the constant said.
  ACTION_STATUS = { process: 'pending', check_pipeline: 'checking_pipeline',
                    fix_discussions: 'fixing_discussions', post_completion: 'done',
                    retry_errored: 'error', retry_stuck: 'pending',
                    recheck_infra: 'done' }.freeze

  setup do
    @config = {
      'gitlab_url' => 'https://gitlab.example.com',
      'gitlab_token' => 'glpat-xxx',
      'max_retries' => 5,
      'projects' => [{ 'path' => PROJECT_PATH, 'max_retries' => 5 }]
    }
    @issue = build_fake_issue
    @client = Object.new
    # Autodev #102: perform_retry_errored now reads the ticket once, before
    # transitioning, to ask HandoverStop whether a human took it back. `nil`
    # labels resolve to "untouched" here since @config's project declares no
    # label_doing/label_done, which is what every test but the handover-specific
    # ones (test/errored_retry_respects_a_handover_test.rb) wants.
    @client.define_singleton_method(:issue) { |*| nil }
  end

  test 'invalid action raises ArgumentError' do
    Config.stub(:load, @config) do
      Issue.stub(:where, ->(**_) { fake_dataset(@issue) }) do
        assert_raises(ArgumentError) { run_perform(:nope) }
      end
    end
  end

  test 'returns silently when project_config is missing' do
    @config['projects'] = []

    Config.stub(:load, @config) do
      assert_nil run_perform(:process)
    end
  end

  test 'returns silently when issue row is missing' do
    Config.stub(:load, @config) do
      Issue.stub(:where, ->(**_) { fake_dataset(nil) }) do
        assert_nil run_perform(:process)
      end
    end
  end

  # -- lookup_project_config (task #9 phase 2: DB read path) --

  test 'lookup_project_config reads the columnized keys from the DB row' do
    Project.create!(gitlab_path: PROJECT_PATH, slug: 'group__foo', target_branch: 'develop', dc_timeout: 900)
    cfg = IssueProcessJob.new.send(:lookup_project_config, @config, PROJECT_PATH)

    assert_equal 'develop', cfg['target_branch']
    assert_equal 900, cfg['dc_timeout']
    # DB is authoritative once a row exists: a standard key set only in the
    # YAML entry is NOT layered back.
    refute cfg.key?('max_retries')
  end

  test 'lookup_project_config reads the advanced keys from the DB row too' do
    Project.create!(gitlab_path: PROJECT_PATH, slug: 'group__foo', target_branch: 'main',
                    model: 'opus', parallel_agents: true, mr_fixer_agent: 'custom')
    # A divergent YAML entry must NOT leak in once a row exists.
    @config['projects'] = [{ 'path' => PROJECT_PATH, 'model' => 'ignored-from-yaml' }]
    cfg = IssueProcessJob.new.send(:lookup_project_config, @config, PROJECT_PATH)

    assert_equal 'opus', cfg['model']
    assert cfg['parallel_agents']
    assert_equal 'custom', cfg['mr_fixer_agent']
  end

  test 'lookup_project_config falls back to the full YAML entry when no DB row exists' do
    cfg = IssueProcessJob.new.send(:lookup_project_config, @config, PROJECT_PATH)

    assert_equal({ 'path' => PROJECT_PATH, 'max_retries' => 5 }, cfg)
  end

  test ':process delegates to IssueProcessor#process' do
    assert_action_routes(:process, klass: IssueProcessor, method: :process)
  end

  test ':check_pipeline delegates to PipelineMonitor#check' do
    assert_action_routes(:check_pipeline, klass: PipelineMonitor, method: :check)
  end

  test ':fix_discussions delegates to MrFixer#fix' do
    assert_action_routes(:fix_discussions, klass: MrFixer, method: :fix)
  end

  test ':retry_errored fires retry_processing for issues without an MR' do
    @issue.status = ACTION_STATUS.fetch(:retry_errored)
    transitions = capture_transitions(@issue)
    Config.stub(:load, @config) do
      Issue.stub(:where, ->(**_) { fake_dataset(@issue) }) do
        ::Config.stub(:label_workflow?, false) do
          GitlabHelpers.stub(:build_gitlab_client, @client) do
            ActivityLogger.stub(:post, true) do
              run_perform(:retry_errored)
            end
          end
        end
      end
    end

    assert_includes transitions, :retry_processing!
  end

  test ':retry_errored fires retry_pipeline when an MR exists' do
    @issue.status = ACTION_STATUS.fetch(:retry_errored)
    @issue.mr_iid = 17
    transitions = capture_transitions(@issue)
    Config.stub(:load, @config) do
      Issue.stub(:where, ->(**_) { fake_dataset(@issue) }) do
        ::Config.stub(:label_workflow?, false) do
          GitlabHelpers.stub(:build_gitlab_client, @client) do
            ActivityLogger.stub(:post, true) do
              run_perform(:retry_errored)
            end
          end
        end
      end
    end

    assert_includes transitions, :retry_pipeline!
  end

  # -- Claude-quota gate (Autodev #46) --
  #
  # PollDispatcher already skips the consuming passes during an outage, but a
  # job enqueued just before the quota ran out is still in the queue. Each of
  # these actions leaves the row in a state the next cycle rediscovers, so
  # returning early loses nothing.

  CONSUMING_ACTIONS = { process: [IssueProcessor, :process],
                        fix_discussions: [MrFixer, :fix] }.freeze

  CONSUMING_ACTIONS.each do |action, (klass, method)|
    test "#{action} is skipped when the Claude quota is exhausted" do
      stub_usage(available: false) do
        refute assert_action_called(action, klass: klass, method: method),
               "expected #{klass}##{method} to be skipped for #{action}"
      end
    end

    test "#{action} still runs when the Claude quota is available" do
      stub_usage(available: true) do
        assert assert_action_called(action, klass: klass, method: method)
      end
    end
  end

  test ':retry_stuck is skipped when the Claude quota is exhausted' do
    stub_usage(available: false) do
      refute assert_action_called(:retry_stuck, klass: IssueProcessor, method: :process)
    end
  end

  # Observation-only actions must never be gated — that is the whole point of
  # the ticket.
  test ':check_pipeline still runs when the Claude quota is exhausted' do
    stub_usage(available: false) do
      assert assert_action_called(:check_pipeline, klass: PipelineMonitor, method: :check)
    end
  end

  # -- Stale-job guard (Autodev #61) --
  #
  # The queue is not a snapshot: `dispatch_pipelines` enqueues the whole
  # `checking_pipeline` population every cycle, and a job that takes longer
  # than the poll interval leaves duplicates behind it. Those duplicates run
  # against a row that has since moved on, and the state machine does not stop
  # them — `whiny_transitions: false` makes an impossible transition a silent
  # no-op, so `green_first_review` calls `launch_review` after a
  # `pipeline_green!` that did nothing, and `give_up_reviewing` posts its
  # GitLab comment after a `review_giveup!` that did nothing.
  #
  # Production, 11/08/2026: issue #15839 recorded 5 `pipeline_green`
  # transitions and 1 `review_giveup` — and 26 identical "mr-review failed 5
  # times" comments, one every 105 seconds, all after the last transition.
  # 486 comments across 28 tickets in two hours.
  #
  # The action carries the state it was dispatched from, so re-reading the row
  # at the top of the job is enough: no lock, no version column, one query
  # already being made.
  test ':check_pipeline is skipped once the row has left checking_pipeline' do
    refute action_reached?(:check_pipeline, status: 'done'),
           'a queued pipeline check must not run against a row already delivered'
  end

  test 'no action reaches its body when the row no longer matches it' do
    IssueProcessJob::ACTIONS.each do |action|
      refute action_reached?(action, status: 'cloning'), "#{action} ran against a row in cloning"
    end
  end

  # The converse, so the guard cannot be "fixed" by simply never dispatching.
  # It also pins ACTION_STATUS against the dispatcher: an action whose source
  # state is misdeclared would silently stop running in production, and this
  # is the test that would catch it.
  test 'every action still reaches its body from the state it is dispatched from' do
    IssueProcessJob::ACTIONS.each do |action|
      assert action_reached?(action, status: ACTION_STATUS.fetch(action)),
             "#{action} did not run from #{ACTION_STATUS.fetch(action)}"
    end
  end

  private

  # Did the job get past the guard? Every action's body is replaced by a flag,
  # which measures the gate itself rather than each action's collaborators —
  # `:retry_errored` reaches no worker class at all, and `:post_completion`
  # fires a transition before it reaches one.
  def action_reached?(action, status:)
    @issue.status = status
    reached = false
    job = IssueProcessJob.new
    job.define_singleton_method(:"perform_#{action}") { |*| reached = true }
    perform_stubbed(job, action)
    reached
  end

  # The quota gate is held open throughout: it is Autodev #46's concern, and
  # letting it fire here would make three of the seven actions look guarded
  # for the wrong reason.
  def perform_stubbed(job, action)
    stub_usage(available: true) do
      Config.stub(:load, @config) do
        Issue.stub(:where, ->(**_) { fake_dataset(@issue) }) do
          GitlabHelpers.stub(:build_gitlab_client, @client) do
            job.perform(PROJECT_PATH, ISSUE_IID, action)
          end
        end
      end
    end
  end

  def stub_usage(available:, &)
    Autodev::UsageGate.stub(:available?, available, &)
  end

  # Same wiring as assert_action_routes, but returns the flag instead of
  # asserting it, so the gate tests can assert either way. `status:` overrides
  # the state the action is dispatched from — that is the whole subject of the
  # stale-job tests.
  def assert_action_called(action, klass:, method:, status: nil) # rubocop:disable Metrics/MethodLength
    @issue.status = status || ACTION_STATUS.fetch(action)
    called = false
    fake_worker = Object.new
    fake_worker.define_singleton_method(method) { |issue| called = !issue.nil? }
    Config.stub(:load, @config) do
      Issue.stub(:where, ->(**_) { fake_dataset(@issue) }) do
        GitlabHelpers.stub(:build_gitlab_client, @client) do
          ActivityLogger.stub(:post, true) do
            klass.stub(:new, fake_worker) { run_perform(action) }
          end
        end
      end
    end
    called
  end

  def run_perform(action)
    IssueProcessJob.new.perform(PROJECT_PATH, ISSUE_IID, action)
  end

  def assert_action_routes(action, klass:, method:) # rubocop:disable Metrics/MethodLength
    @issue.status = ACTION_STATUS.fetch(action)
    called = false
    fake_worker = Object.new
    fake_worker.define_singleton_method(method) do |issue|
      called = !issue.nil?
    end
    Config.stub(:load, @config) do
      Issue.stub(:where, ->(**_) { fake_dataset(@issue) }) do
        GitlabHelpers.stub(:build_gitlab_client, @client) do
          klass.stub(:new, fake_worker) do
            run_perform(action)
          end
        end
      end
    end

    assert called, "expected #{klass}##{method} to be called for #{action}"
  end

  def build_fake_issue
    Struct.new(:issue_iid, :mr_iid, :status, :retry_count) do
      def update(**) = self
      def retry_processing! = nil
      def retry_pipeline! = nil
      # Autodev #102: perform_retry_errored's handover check calls this via
      # ExternalState#stop_on_handover before it does anything else.
      def may_close? = true
    end.new(ISSUE_IID, nil, 'pending', 0)
  end

  def capture_transitions(issue)
    transitions = []
    %i[retry_processing! retry_pipeline! update].each do |meth|
      original = issue.method(meth)
      issue.define_singleton_method(meth) do |*args, **kwargs|
        transitions << meth
        original.call(*args, **kwargs)
      end
    end
    transitions
  end

  def fake_dataset(row)
    Struct.new(:row) do
      def first = row
    end.new(row)
  end
end
