# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class ProjectBrieferTest < ActiveSupport::TestCase
    setup do
      @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
      @config = { 'gitlab_url' => 'https://gitlab.example.com', 'gitlab_token' => 't0k3n' }
    end

    teardown do
      ProjectBriefer.stub_invoker = nil
    end

    # The stub_invoker bypasses the git-clone + danger-claude calls;
    # only the post-invocation storage path is exercised here. The
    # end-to-end clone path can't run in CI (no GitLab server, no
    # danger-claude binary in tests) — that's a manual smoke.
    def stub_with(briefing: '# briefing', error: nil)
      ProjectBriefer.stub_invoker = lambda do |_work_dir, _prompt|
        raise ProjectBriefer::RefreshFailed, error if error

        briefing
      end
    end

    # --- happy path -------------------------------------------------

    def test_refresh_stores_briefing_text_and_timestamp
      stub_with(briefing: "# Project briefing\n\nDomain: …")
      bypass_clone do
        ProjectBriefer.new(@project, config: @config).refresh!
      end
      @project.reload

      assert_equal "# Project briefing\n\nDomain: …", @project.briefing_text
      assert_not_nil @project.briefing_generated_at
      assert_nil @project.briefing_error
    end

    def test_refresh_clears_previous_error_on_success
      @project.update!(briefing_error: 'previous failure')
      stub_with(briefing: 'fresh briefing')
      bypass_clone { ProjectBriefer.new(@project, config: @config).refresh! }

      assert_nil @project.reload.briefing_error
    end

    # --- error paths ------------------------------------------------

    def test_refresh_keeps_previous_text_on_failure # rubocop:disable Metrics/MethodLength
      @project.update!(briefing_text: 'old briefing',
                       briefing_generated_at: 1.day.ago,
                       briefing_error: nil)
      stub_with(error: 'danger-claude crashed')

      bypass_clone do
        assert_raises(ProjectBriefer::RefreshFailed) do
          ProjectBriefer.new(@project, config: @config).refresh!
        end
      end

      @project.reload

      assert_equal 'old briefing', @project.briefing_text
      assert_equal 'danger-claude crashed', @project.briefing_error
    end

    def test_refresh_raises_when_gitlab_token_missing
      stub_with # invoker is set but we won't reach it
      assert_raises(ProjectBriefer::RefreshFailed) do
        ProjectBriefer.new(@project, config: { 'gitlab_url' => 'https://gitlab.example.com' }).refresh!
      end
    end

    # ----------------------------------------------------------------
    # The `bypass_clone` helper short-circuits the actual git clone +
    # branch detection by stubbing Open3.capture3 to return success.
    # The stub_invoker handles the danger-claude path. End-to-end
    # clone behaviour belongs to a manual smoke test against a real
    # GitLab project.
    def bypass_clone(&)
      Open3.stub :capture3, ->(*_args, **_opts) { ['', '', FakeStatus.new(true)] }, &
    end

    FakeStatus = Struct.new(:success?)
  end
end
