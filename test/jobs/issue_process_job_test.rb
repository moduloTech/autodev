# frozen_string_literal: true

require_relative '../rails_helper'

# AUTODEV_SKIP_LEGACY=1 (set in rails_helper) prevents the legacy_sinatra
# initializer from loading lib/autodev — and we deliberately don't load it
# here either, because that would pull in pastel/sequel/etc. and collide
# with `test/stub_autodev.rb`'s constants when rake test runs both halves
# of the suite in one process. Stub the legacy collaborators referenced by
# the job at the top-level constant so `Klass.stub(...)` resolves.
unless defined?(Config)
  config_stub = Module.new
  config_stub.define_singleton_method(:load) { |*| {} }
  config_stub.define_singleton_method(:label_workflow?) { |_| false }
  Object.const_set(:Config, config_stub)
end
Object.const_set(:Issue, Class.new { def self.where(**); end }) unless defined?(Issue)
unless defined?(GitlabHelpers)
  helper_stub = Module.new
  helper_stub.define_singleton_method(:build_gitlab_client) { |*| nil }
  Object.const_set(:GitlabHelpers, helper_stub)
end
%i[IssueProcessor PipelineMonitor MrFixer].each do |name|
  next if Object.const_defined?(name)

  Object.const_set(name, Class.new { def self.new(**); end })
end
unless defined?(ActivityLogger)
  activity_stub = Module.new
  activity_stub.define_singleton_method(:post) { |*| nil }
  activity_stub.const_set(:Ctx, Class.new { def initialize(*); end })
  Object.const_set(:ActivityLogger, activity_stub)
end

# Wiring test for IssueProcessJob — verifies each :action symbol routes to
# the right legacy worker without going through GitLab or Sequel for real.
# The job's value is the dispatch table; the per-action workers themselves
# are already covered by their own existing tests.
class IssueProcessJobTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  PROJECT_PATH = 'group/foo'
  ISSUE_IID = 42

  setup do
    @config = {
      'gitlab_url' => 'https://gitlab.example.com',
      'gitlab_token' => 'glpat-xxx',
      'max_retries' => 5,
      'projects' => [{ 'path' => PROJECT_PATH, 'max_retries' => 5 }]
    }
    @issue = build_fake_issue
    @client = Object.new
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

  private

  def run_perform(action)
    IssueProcessJob.new.perform(PROJECT_PATH, ISSUE_IID, action)
  end

  def assert_action_routes(action, klass:, method:) # rubocop:disable Metrics/MethodLength
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
