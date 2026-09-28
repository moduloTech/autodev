# frozen_string_literal: true

require 'autodev/gitlab_helpers'

# Shared by the two files that pin the `post_completion` reservation (Autodev
# #114): `test/post_completion_runs_once_test.rb` (the pass) and
# `test/a_post_completion_reservation_is_one_deliverys_test.rb` (its lifecycle).
module PostCompletionFixtures
  PROJECT_CONFIG = {
    'path' => 'group/project',
    'post_completion' => [%w[bin/deploy]],
    'labels_todo' => ['To Do'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  AUTODEV_ID = 7
  HUMAN_ID = 999

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)
  FakeMr = Struct.new(:state)

  class StubClient
    def initialize(assignee_ids: [HUMAN_ID], mr_state: 'opened')
      @assignee_ids = assignee_ids
      @mr_state = mr_state
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      FakeIssue.new('opened', @assignee_ids.map { |id| FakeAssignee.new(id) }, [])
    end

    def merge_request(_project, _iid) = FakeMr.new(@mr_state)
  end

  # Counts the pass's two GitLab reads, which is what the selection's
  # `IS NULL` clause is for: the compare-and-set alone would already refuse a
  # stamped row, so without a count its absence is invisible.
  class CountingClient < StubClient
    attr_reader :reads

    def initialize(**)
      super
      @reads = 0
    end

    def issue(*)
      @reads += 1
      super
    end

    def merge_request(*)
      @reads += 1
      super
    end
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def dispatcher(client = StubClient.new)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, PROJECT_CONFIG['path'])
      d.instance_variable_set(:@project_config, PROJECT_CONFIG)
      d.instance_variable_set(:@config, CONFIG)
      d.instance_variable_set(:@logger, StubLogger.new)
      d.instance_variable_set(:@client, client)
    end
  end

  def cycles(count, client = StubClient.new)
    enqueued = []
    IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
      count.times { dispatcher(client).send(:dispatch_done_unassigned) }
    end
    enqueued
  end

  def delivered(**attrs)
    create_issue(status: 'done', mr_iid: 42, **attrs)
  end

  def resume_handler
    PollRouter.allocate.tap do |r|
      r.instance_variable_set(:@project_path, PROJECT_CONFIG['path'])
      r.instance_variable_set(:@project_config, PROJECT_CONFIG)
      r.instance_variable_set(:@logger, StubLogger.new)
      r.define_singleton_method(:apply_label_doing) { |_iid| nil }
      r.define_singleton_method(:log_activity) { |*_args, **_kw| nil }
      r.define_singleton_method(:enqueue_issue_processing) { |*_args| nil }
    end
  end

  # Runs the job's `post_completion` action with the hook itself replaced by the
  # block, so what is measured is the job's own guard and its `ensure`.
  # `reservation` defaults to the row's own stamp: a job enqueued for it.
  def perform_hook(issue, reservation = issue.post_completion_dispatched_at&.to_i, &)
    monitor = Object.new
    monitor.define_singleton_method(:run_post_completion, &)
    GitlabHelpers.stub(:build_gitlab_client, Object.new) do
      ActivityLogger.stub(:post, nil) do
        PipelineMonitor.stub(:new, monitor) do
          IssueProcessJob.new.send(:perform_post_completion, issue, CONFIG, PROJECT_CONFIG, reservation)
        end
      end
    end
  end

  # Takes a delivered row back into work and delivers it again, the way a human
  # reposing the todo label and a green pipeline would.
  def redeliver(issue)
    resume_handler.send(:reenter_via_pipeline_check, issue.reload)
    Issue.where(id: issue.id).update_all(status: 'done')
    issue.reload
  end
end

# Shared by the two files that pin what a failed `post_completion` produces
# (Autodev #94): `test/a_failed_post_completion_says_so_test.rb` (every cause
# reaches the sink) and `test/the_post_completion_comment_says_what_it_may_test.rb`
# (what the comment carries, and what it never does). The command is really
# spawned; only the clone is stubbed, the one step that needs a GitLab remote.
module PostCompletionFailureFixtures
  PATH = 'group/project'
  SECRET = 'glpat-SECRETSECRETSECRET'
  # What the command prints, assembled by `printf` so that the command's own text
  # (which the comment does carry) never contains it.
  MARKER = 'MARKER-OUTPUT'
  PRINTS_MARKER = "printf '%s-%s' MARKER OUTPUT"

  class RecordingClient
    def notes = (@notes ||= [])
    def create_issue_note(_project, iid, body) = notes << [iid, body]
  end

  def setup
    setup_database
    @client = RecordingClient.new
    # The state the job puts the row in before it runs the hook.
    @issue = create_issue(project_path: PATH, status: 'running_post_completion', mr_iid: 42, branch_name: 'feat/x',
                          mr_url: 'https://gitlab.example/group/project/-/merge_requests/42', locale: 'en')
  end

  def monitor(timeout: 60, clone: ->(dir, _branch) { FileUtils.mkdir_p(dir) })
    PipelineMonitor.new(client: @client, config: { 'gitlab_url' => 'https://gitlab.example' },
                        project_config: { 'path' => PATH, 'post_completion_timeout' => timeout },
                        logger: StubLogger.new, token: 'x').tap do |m|
      m.define_singleton_method(:clone_and_checkout, &clone)
    end
  end

  def comments = @client.notes.map(&:last)
end
