# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# Where `mr-review` is started from (Autodev #77).
#
# The call used to pass `chdir: Dir.pwd` with the comment "keeps the previous
# behaviour" — an absence of decision inherited from the Open3.capture3 era,
# where the cwd was simply whatever the worker happened to have. In production
# that is `/Users/modulotech`, the `WorkingDirectory` of the launchd plist; from
# a developer's terminal it is wherever `bin/autodev` was typed. A cwd nobody
# chose is also what made Autodev #77's original diagnosis ("mr-review reads
# autodev's own CLAUDE.md as the project conventions") plausible on reading.
#
# It is now `Dir.tmpdir`: neutral, declared, and always present. Nothing in the
# run depends on it — `mr-review` clones the MR's source branch itself
# (/tmp/mr-review_<iid>_<pid>) and `cd`s into that clone for every command it
# delegates, and every other path it touches is absolute (`~/.mr-review/
# mr-review.db`, its tempfiles). What matters is only that the directory exists:
# `Process.spawn` fails outright on a `chdir:` that does not.
class MrReviewRunsInANeutralDirectoryTest < Minitest::Test
  include DatabaseTestHelper

  class Harness
    include DangerClaudeRunner
    include PipelineMonitor::Reviewer

    def initialize(issue:, logger:)
      init_runner(client: nil, config: {}, project_config: { 'path' => 'group/project' },
                  logger: logger, token: 'tok')
      @dc_issue = issue
    end
  end

  MR_URL = 'https://gitlab.example/group/project/-/merge_requests/1'

  def setup
    setup_database
    @issue = create_issue(status: 'reviewing')
    @harness = Harness.new(issue: @issue, logger: StubLogger.new)
    @calls = []
    calls = @calls
    @harness.define_singleton_method(:run_with_timeout) do |cmd, args, **opts|
      calls << { cmd: cmd, args: args, opts: opts }
      ['', '', true]
    end
  end

  def chdir_passed
    @harness.send(:run_mr_review_command, MR_URL)
    @calls.first[:opts][:chdir]
  end

  def test_the_directory_is_the_declared_neutral_one
    assert_equal Dir.tmpdir, chdir_passed
  end

  # The whole point: the worker's own cwd stops being an input. Run the call from
  # somewhere else entirely and nothing about the spawn moves.
  def test_the_workers_current_directory_is_not_an_input
    from_elsewhere = Dir.mktmpdir { |elsewhere| Dir.chdir(elsewhere) { chdir_passed } }

    assert_equal Dir.tmpdir, from_elsewhere
  end

  # Process.spawn raises Errno::ENOENT on a chdir that is not there, which would
  # turn every review into a review failure.
  def test_the_directory_exists
    assert_path_exists chdir_passed
    assert File.directory?(chdir_passed), 'chdir must name a directory'
  end
end
