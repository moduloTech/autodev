# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/shell_helpers'

# Regression for task #10: a failing git command must not leak the PAT
# (embedded in the clone URL) into the GitError it raises — that message is
# persisted to issues.error_message and posted as a GitLab comment.
class ShellHelpersRedactionTest < Minitest::Test
  include ShellHelpers

  def test_failed_command_raises_a_scrubbed_git_error
    # `git ls-remote` against a bogus authenticated URL fails fast offline.
    url = 'https://oauth2:glpat-LEAKME123@127.0.0.1:1/group/proj.git'
    error = assert_raises(GitError) do
      ShellHelpers.run_cmd(['git', 'ls-remote', url])
    end

    refute_includes error.message, 'glpat-LEAKME123'
    assert_includes error.message, 'oauth2:***@'
  end
end
