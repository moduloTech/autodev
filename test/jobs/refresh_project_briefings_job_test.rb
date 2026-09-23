# frozen_string_literal: true

require_relative '../rails_helper'

# Autodev #117: a failed clone used to surface as an Errno::ENOENT that the
# job's `rescue RefreshFailed` let through, aborting `find_each` — the next
# project was never attempted. A refresh failure must now stay one project's
# problem, while a genuine bug still takes the job down.
class RefreshProjectBriefingsJobTest < ActiveSupport::TestCase
  FakeStatus = Struct.new(:success?)
  GIT_OK = ['', '', FakeStatus.new(true)].freeze

  setup do
    @saved_config = ::Web.config
    ::Web.config = { 'gitlab_url' => 'https://gitlab.example.com', 'gitlab_token' => 't0k3n' }
    Autospec::ProjectBriefer.stub_invoker = ->(*) { 'ok' }
  end

  teardown do
    Autospec::ProjectBriefer.stub_invoker = nil
    ::Web.config = @saved_config
  end

  # ls-remote finds no staging and no symref line (→ main); the clone fails
  # only for the repository whose path the caller names.
  def with_clone_failing_for(gitlab_path, &)
    responder = lambda do |*args, **_opts|
      argv = args.grep(String)
      next GIT_OK unless argv.include?('clone')
      next ['', "fatal: repository '#{gitlab_path}' not found", FakeStatus.new(false)] if
        argv.any? { |arg| arg.include?("/#{gitlab_path}.git") }

      GIT_OK
    end
    Open3.stub(:capture3, responder, &)
  end

  test 'a failed clone is stored on its project and the next project still refreshes' do
    first = Project.create!(gitlab_path: 'group/one', slug: 'group__one')
    second = Project.create!(gitlab_path: 'group/two', slug: 'group__two')

    with_clone_failing_for('group/one') { RefreshProjectBriefingsJob.perform_now }

    assert_match(/git clone/, first.reload.briefing_error)
    assert_nil first.briefing_text
    assert_equal 'ok', second.reload.briefing_text
  end

  test 'a failure that is not a refresh failure still propagates out of the job' do
    project = Project.create!(gitlab_path: 'group/one', slug: 'group__one')
    # An invalid row makes store_success!'s update! raise — a bug, not an outage.
    project.update_column(:default_locale, 'xx')

    with_clone_failing_for('none/such') do
      assert_raises(ActiveRecord::RecordInvalid) { RefreshProjectBriefingsJob.perform_now }
    end
  end
end
