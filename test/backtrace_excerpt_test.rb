# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'
require 'autodev/issue_processor'

# Autodev #125: `error_message` kept only the first ten frames of a backtrace,
# and a transport error raised inside `net-http` spends all ten in the gem — the
# frame that says which autodev call was cut never reached the row or the log.
class BacktraceExcerptTest < Minitest::Test
  include DatabaseTestHelper

  # Spelt out rather than read from `BacktraceExcerpt::ROOT`, so the handler
  # tests fail on their assertion, not on a missing constant, before the change.
  APP_ROOT = File.expand_path('..', __dir__)
  GEM_FRAME = '/opt/homebrew/lib/ruby/gems/4.0.0/gems/net-http-0.9.1/lib/net/http.rb:%d:in \'connect\''
  CUT_FRAME = "#{APP_ROOT}/lib/autodev/mr_fixer.rb:150:in 'resolve_discussion'".freeze

  class SilentClient
    def method_missing(*, **) = nil
    def respond_to_missing?(*) = true
  end

  def setup = setup_database

  def own(num) = "#{APP_ROOT}/lib/autodev/own_#{num}.rb:#{num}:in 'call'"
  def gem(num) = format(GEM_FRAME, num)

  def error_with(backtrace)
    error = Net::OpenTimeout.new('execution expired')
    error.set_backtrace(backtrace)
    error
  end

  # --- lines -------------------------------------------------------------

  def test_lines_is_the_head_followed_by_the_next_own_frames
    head = (1..5).map { own(it) } + (1..5).map { gem(it) }
    tail = (101..115).map { own(it) }

    assert_equal head + tail.first(10), BacktraceExcerpt.lines(error_with(head + tail))
  end

  def test_lines_does_not_repeat_an_own_frame_the_head_already_shows
    head = (1..5).map { own(it) } + (1..5).map { gem(it) }
    tail = [own(1), gem(6), own(2)]

    assert_equal head, BacktraceExcerpt.lines(error_with(head + tail))
  end

  def test_lines_is_empty_without_a_backtrace
    assert_empty BacktraceExcerpt.lines(Net::OpenTimeout.new('no backtrace'))
    assert_nil BacktraceExcerpt.format(Net::OpenTimeout.new('no backtrace'))
  end

  def test_format_joins_the_lines_the_way_error_message_always_has
    assert_equal "#{own(1)}\n  #{gem(2)}", BacktraceExcerpt.format(error_with([own(1), gem(2)]))
  end

  # --- own_frame? --------------------------------------------------------

  def test_own_frame_is_a_path_under_the_application_root
    assert_equal APP_ROOT, BacktraceExcerpt::ROOT
    assert BacktraceExcerpt.own_frame?("#{BacktraceExcerpt::ROOT}/lib/x.rb:1")
  end

  # The Homebrew install keeps its gems under `libexec/vendor/bundle`, i.e.
  # under ROOT, and a sibling checkout shares ROOT as a string prefix.
  def test_own_frame_excludes_a_sibling_directory_the_vendored_gems_and_a_gem_outside_root
    root = BacktraceExcerpt::ROOT
    others = ["#{root}-other/lib/x.rb:1",
              "#{root}/vendor/bundle/ruby/4.0.0/gems/gitlab-5.1.0/lib/gitlab.rb:1",
              gem(1)]

    assert_equal([false, false, false], others.map { BacktraceExcerpt.own_frame?(it) })
  end

  # --- the three error_message writers ----------------------------------

  def worker(klass, logger)
    w = klass.allocate
    w.instance_variable_set(:@project_path, 'group/project')
    w.instance_variable_set(:@project_config, {})
    w.instance_variable_set(:@config, {})
    w.instance_variable_set(:@client, SilentClient.new)
    w.instance_variable_set(:@logger, logger)
    w.instance_variable_set(:@dc_stdout, '')
    w.instance_variable_set(:@dc_stderr, '')
    w
  end

  def cut_in_net_http = error_with((1..12).map { gem(it) } + [CUT_FRAME])

  def assert_the_cut_frame_is_kept(klass, handler, status)
    issue = create_issue(status: status)
    logger = StubLogger.new
    worker(klass, logger).send(handler, issue, cut_in_net_http)

    assert_includes issue.reload.error_message, 'lib/autodev/mr_fixer.rb:150'
    assert logger.messages.any? { it.include?('lib/autodev/mr_fixer.rb:150') },
           "no logged line carries the cut frame:\n#{logger.messages.join("\n")}"
  end

  def test_mr_fixer_keeps_the_autodev_frame_behind_ten_gem_frames
    assert_the_cut_frame_is_kept(MrFixer, :handle_fix_error, 'fixing_discussions')
  end

  def test_pipeline_monitor_keeps_the_autodev_frame_behind_ten_gem_frames
    assert_the_cut_frame_is_kept(PipelineMonitor, :handle_failure_error, 'fixing_pipeline')
  end

  def test_issue_processor_keeps_the_autodev_frame_behind_ten_gem_frames
    assert_the_cut_frame_is_kept(IssueProcessor, :handle_process_error, 'implementing')
  end
end
