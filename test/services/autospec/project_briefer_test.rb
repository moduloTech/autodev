# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class ProjectBrieferTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
    FakeStatus = Struct.new(:success?)
    # What `run_with_timeout` hands back as its fourth element: a process that
    # exited carries an exitstatus, one killed by a signal carries only a termsig.
    FakeProcessStatus = Struct.new(:exitstatus, :termsig)

    GIT_OK = ['', '', FakeStatus.new(true)].freeze
    STAGING_LISTED = ["abc123\trefs/heads/staging", '', FakeStatus.new(true)].freeze
    # Long enough that cutting at 400 *before* scrubbing lands inside the
    # token, before its `@` — the shape URL_CREDENTIALS then fails to match.
    LEAKY_STDERR = "#{'x' * 370}fatal: https://oauth2:s3cr3tt0k3nABCDEFGH@host/g/p.git".freeze

    setup do
      @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
      @config = { 'gitlab_url' => 'https://gitlab.example.com', 'gitlab_token' => 't0k3n' }
      @git_calls = []
    end

    teardown do
      ProjectBriefer.stub_invoker = nil
    end

    def stub_with(briefing: '# briefing', error: nil)
      ProjectBriefer.stub_invoker = lambda do |_work_dir, _prompt|
        raise ProjectBriefer::RefreshFailed, error if error

        briefing
      end
    end

    # A test that expects the refresh to stop before danger-claude must not
    # make reaching it look like a failure the code under test produced — a
    # RefreshFailed from here would satisfy the very assertion it guards.
    def forbid_danger_claude
      ProjectBriefer.stub_invoker = ->(*) { flunk 'danger-claude was reached' }
    end

    def briefer
      ProjectBriefer.new(@project, config: @config)
    end

    # Stubs Open3.capture3 per git subcommand. Dispatches on argv *content*:
    # `ShellHelpers.run_cmd_status` passes its env Hash first, so `args[0]` is
    # `{}`, never 'git'. A reply is a capture3 triple or a callable taking the
    # argv; a `--symref` left unset flunks, so a test proves it was not asked.
    def with_git(heads: STAGING_LISTED, symref: nil, clone: GIT_OK, &)
      responder = lambda do |*args, **_opts|
        argv = args.grep(String)
        @git_calls << argv
        reply = git_reply(argv, heads, symref, clone)
        reply.respond_to?(:call) ? reply.call(argv) : reply
      end
      Open3.stub(:capture3, responder, &)
    end

    def git_reply(argv, heads, symref, clone)
      return heads if argv.include?('--heads')
      return symref || flunk("--symref consulted: #{argv.inspect}") if argv.include?('--symref')
      return clone if argv.include?('clone')

      flunk("unexpected command through capture3: #{argv.inspect}")
    end

    def clone_calls
      @git_calls.select { |argv| argv.include?('clone') }
    end

    def cloned_branch
      argv = clone_calls.last
      argv[argv.index('--branch') + 1]
    end

    # Clone stub that leaves the directory a real clone would, so a real
    # danger-claude spawn has a `chdir:` to land in.
    def clone_creating_dir
      lambda do |argv|
        FileUtils.mkdir_p(argv.last)
        GIT_OK
      end
    end

    def with_fake_danger_claude(script)
      original_path = ENV.fetch('PATH')
      Dir.mktmpdir('fake_danger_claude_') do |bin|
        path = File.join(bin, 'danger-claude')
        File.write(path, "#!/bin/sh\n#{script}\n")
        File.chmod(0o755, path)
        ENV['PATH'] = "#{bin}:#{original_path}"
        yield
      end
    ensure
      ENV['PATH'] = original_path
    end

    def with_danger_claude_timeout(seconds)
      original = ProjectBriefer::DANGER_CLAUDE_TIMEOUT
      swap_timeout(seconds)
      yield
    ensure
      swap_timeout(original)
    end

    def swap_timeout(value)
      ProjectBriefer.send(:remove_const, :DANGER_CLAUDE_TIMEOUT)
      ProjectBriefer.const_set(:DANGER_CLAUDE_TIMEOUT, value)
    end

    # Runs refresh! with `run_with_timeout` answering a failed process, and
    # returns the RefreshFailed it raised.
    def danger_claude_failure(out:, err:, status: FakeProcessStatus.new(1, nil))
      subject = briefer
      subject.stub(:run_with_timeout, ->(*, **) { [out, err, false, status] }) do
        with_git { assert_raises(ProjectBriefer::RefreshFailed) { subject.refresh! } }
      end
    end

    # --- happy path -------------------------------------------------

    def test_refresh_stores_briefing_text_and_timestamp
      stub_with(briefing: "# Project briefing\n\nDomain: …")
      with_git { briefer.refresh! }
      @project.reload

      assert_equal "# Project briefing\n\nDomain: …", @project.briefing_text
      assert_not_nil @project.briefing_generated_at
      assert_nil @project.briefing_error
    end

    def test_refresh_clears_previous_error_on_success
      @project.update!(briefing_error: 'previous failure')
      stub_with(briefing: 'fresh briefing')
      with_git { briefer.refresh! }

      assert_nil @project.reload.briefing_error
    end

    # --- error paths ------------------------------------------------

    def test_refresh_keeps_previous_text_on_failure # rubocop:disable Metrics/MethodLength
      @project.update!(briefing_text: 'old briefing',
                       briefing_generated_at: 1.day.ago,
                       briefing_error: nil)
      stub_with(error: 'danger-claude crashed')

      with_git do
        assert_raises(ProjectBriefer::RefreshFailed) do
          briefer.refresh!
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

    # --- git: the status is read, not the object (Autodev #117) -----

    # A1
    def test_a_failed_clone_raises_and_stores_gits_stderr
      forbid_danger_claude
      error = with_git(heads: GIT_OK, symref: GIT_OK, clone: ['', 'fatal: x', FakeStatus.new(false)]) do
        refresh_failure
      end

      assert_match(/fatal: x/, error.message)
      assert_match(/git clone \(main\) failed: fatal: x/, @project.reload.briefing_error)
    end

    # A2
    def test_a_failed_ls_remote_heads_raises_without_guessing_a_branch
      forbid_danger_claude
      error = with_git(heads: ['', 'fatal: unable to access', FakeStatus.new(false)]) { refresh_failure }

      assert_match(/ls-remote \(staging\) failed: fatal: unable to access/, error.message)
      assert_empty clone_calls
      assert_match(/ls-remote \(staging\)/, @project.reload.briefing_error)
    end

    # A3
    def test_a_listed_staging_branch_is_cloned
      stub_with
      with_git(heads: STAGING_LISTED) { briefer.refresh! }

      assert_equal 'staging', cloned_branch
    end

    # A4
    def test_no_staging_and_no_symref_line_falls_back_to_main
      stub_with
      with_git(heads: GIT_OK, symref: ["0abc\tHEAD", '', FakeStatus.new(true)]) { briefer.refresh! }

      assert_equal 'main', cloned_branch
    end

    # A4
    def test_no_staging_clones_the_remote_default_branch
      stub_with
      symref = ["ref: refs/heads/master\tHEAD\n0abc\tHEAD", '', FakeStatus.new(true)]
      with_git(heads: GIT_OK, symref: symref) { briefer.refresh! }

      assert_equal 'master', cloned_branch
    end

    # A5
    def test_a_failed_ls_remote_symref_raises_instead_of_cloning_main
      forbid_danger_claude
      error = with_git(heads: GIT_OK, symref: ['', 'fatal: dns', FakeStatus.new(false)]) { refresh_failure }

      assert_match(/ls-remote \(HEAD\) failed: fatal: dns/, error.message)
      assert_empty clone_calls
    end

    # A6
    def test_git_missing_is_a_stored_refresh_failure
      forbid_danger_claude
      missing = ->(_argv) { raise Errno::ENOENT, 'git' }
      error = with_git(heads: missing) { refresh_failure }

      assert_match(/git ls-remote \(staging\) could not run: No such file or directory/, error.message)
      assert_equal error.message, @project.reload.briefing_error
    end

    # --- danger-claude through ProcessRunner ------------------------

    # A7
    def test_danger_claude_that_cannot_spawn_is_a_stored_refresh_failure
      error = with_git { refresh_failure }

      assert_match(/danger-claude could not run: No such file or directory/, error.message)
      assert_equal error.message, @project.reload.briefing_error
    end

    # A8
    def test_a_real_danger_claude_child_output_is_the_briefing
      with_fake_danger_claude("echo '# briefing'") do
        with_git(clone: clone_creating_dir) { briefer.refresh! }
      end

      assert_equal '# briefing', @project.reload.briefing_text
    end

    # A8
    def test_a_real_danger_claude_child_exit_is_named_with_its_stdout
      error = with_fake_danger_claude('echo "quota exceeded"; exit 3') do
        with_git(clone: clone_creating_dir) { refresh_failure }
      end

      assert_match(/exit 3/, error.message)
      assert_match(/quota exceeded/, error.message)
    end

    # A9
    def test_a_hung_danger_claude_times_out_into_a_stored_refresh_failure
      error = with_danger_claude_timeout(1) do
        with_fake_danger_claude('sleep 30') do
          with_git(clone: clone_creating_dir) { refresh_failure }
        end
      end

      assert_match(/timed out after 1s/, error.message)
      assert_match(/timed out after 1s/, @project.reload.briefing_error)
    end

    # A10
    def test_a_killed_danger_claude_is_named_by_its_signal
      error = danger_claude_failure(out: '', err: '', status: FakeProcessStatus.new(nil, 9))

      assert_match(/signal 9/, error.message)
      assert_no_match(/exit/, error.message)
    end

    # A11
    def test_danger_claude_failure_prefers_stderr_over_stdout
      error = danger_claude_failure(out: 'O', err: "E\n")

      assert_equal 'danger-claude failed (exit 1): E', error.message
    end

    # A11
    def test_danger_claude_failure_keeps_the_tail_of_stdout
      error = danger_claude_failure(out: "#{'a' * 600}END", err: '')
      detail = error.message.delete_prefix('danger-claude failed (exit 1): ')

      assert_match(/END\z/, detail)
      assert_operator detail.length, :<=, 400
    end

    # A11
    def test_danger_claude_failure_without_output_says_so
      error = danger_claude_failure(out: " \n", err: '')

      assert_match(/\): no output\z/, error.message)
    end

    # A12
    def test_danger_claude_empty_success_output_keeps_its_message
      subject = briefer
      subject.stub(:run_with_timeout, ->(*, **) { ["\n", '', true, FakeProcessStatus.new(0, nil)] }) do
        error = with_git { assert_raises(ProjectBriefer::RefreshFailed) { subject.refresh! } }

        assert_equal 'danger-claude returned empty output', error.message
      end
    end

    # A16
    def test_danger_claude_timeout_is_ten_minutes
      assert_equal 600, ProjectBriefer::DANGER_CLAUDE_TIMEOUT
    end

    # A16 / item 8
    def test_danger_claude_is_capped_by_the_briefing_timeout
      captured = nil
      subject = briefer
      spy = lambda do |*_args, **kwargs|
        captured = kwargs
        ['# briefing', '', true, FakeProcessStatus.new(0, nil)]
      end
      subject.stub(:run_with_timeout, spy) { with_git { subject.refresh! } }

      assert_equal ProjectBriefer::DANGER_CLAUDE_TIMEOUT, captured[:timeout]
    end

    # A16
    def test_danger_claude_spawns_under_clean_env
      env = nil
      spawn = lambda do |child_env, *_rest, **_opts|
        env = child_env
        raise Errno::ENOENT, 'danger-claude'
      end
      Process.stub(:spawn, spawn) { with_git { refresh_failure } }

      assert_includes env.keys, 'GEM_HOME'
      assert_nil env['GEM_HOME']
    end

    # --- scrubbing --------------------------------------------------

    # A13
    def test_clone_stderr_is_scrubbed_before_it_is_cut
      forbid_danger_claude
      with_git(clone: ['', LEAKY_STDERR, FakeStatus.new(false)]) { refresh_failure }

      assert_not_includes @project.reload.briefing_error, 's3cr3t'
      assert_includes @project.briefing_error, 'oauth2:***@'
    end

    # A13
    def test_ls_remote_stderr_is_scrubbed_before_it_is_cut
      forbid_danger_claude
      with_git(heads: ['', LEAKY_STDERR, FakeStatus.new(false)]) { refresh_failure }

      assert_not_includes @project.reload.briefing_error, 's3cr3t'
    end

    # A13
    def test_danger_claude_stdout_tail_is_scrubbed
      danger_claude_failure(out: LEAKY_STDERR, err: '')

      assert_not_includes @project.reload.briefing_error, 's3cr3t'
    end

    # --- what is not a refresh failure ------------------------------

    # A14
    def test_a_full_disk_is_not_a_briefing_failure
      stub_with

      Dir.stub(:mktmpdir, ->(*) { raise Errno::ENOSPC }) do
        assert_raises(Errno::ENOSPC) { briefer.refresh! }
      end

      assert_nil @project.reload.briefing_error
    end

    # A15 — a bug escapes to Solid Queue rather than being filed under
    # briefing_error next to network outages.
    def test_a_failed_store_propagates_unchanged_and_is_not_stored
      @project.update_column(:default_locale, 'xx')
      stub_with

      with_git do
        assert_raises(ActiveRecord::RecordInvalid) { briefer.refresh! }
      end

      assert_nil @project.reload.briefing_error
    end

    private

    def refresh_failure
      assert_raises(ProjectBriefer::RefreshFailed) { briefer.refresh! }
    end
  end
end
