# frozen_string_literal: true

require_relative '../../test_helper'
require 'fileutils'

module Autodev
  # Filesystem-only coverage for the log housekeeping: prune dated JSONL +
  # rotation archives past the window, copy-truncate the oversized held logs.
  class LogJanitorTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @home = @dir
      @rails_log = File.join(@home, 'log')
      @app_log = File.join(@home, 'logs')
      FileUtils.mkdir_p(File.join(@app_log, 'autodev'))
      FileUtils.mkdir_p(@rails_log)
      @now = Time.now
      @old = @now - (60 * 86_400)
    end

    def teardown
      FileUtils.remove_entry(@dir)
    end

    def write(path, content, mtime: @now)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      File.utime(mtime, mtime, path)
      path
    end

    def janitor(**)
      LogJanitor.new(home: @home, app_log_dir: @app_log, rails_env: 'production',
                     max_bytes: 100, now: @now, **)
    end

    def test_prunes_old_jsonl_and_keeps_recent
      old = write(File.join(@app_log, 'autodev', '2026-01-01.jsonl'), "{}\n", mtime: @old)
      recent = write(File.join(@app_log, 'autodev', 'today.jsonl'), "{}\n")

      janitor.run

      refute_path_exists old
      assert_path_exists recent
    end

    def test_prunes_old_archive_but_keeps_live_rails_log
      old_archive = write(File.join(@rails_log, 'production.log.20260101'), 'x', mtime: @old)
      live = write(File.join(@rails_log, 'production.log'), 'x', mtime: @old)

      janitor.run

      refute_path_exists old_archive
      assert_path_exists live, 'the live <env>.log is never pruned, only its archives'
    end

    def test_copy_truncates_oversized_held_log
      path = write(File.join(@rails_log, 'autodev-stdout.log'), 'A' * 200)

      result = janitor.run

      assert_equal 0, File.size(path), 'original is truncated in place'
      assert_equal 1, Dir.glob(File.join(@rails_log, 'autodev-stdout.log.*')).size
      assert_includes result[:rotated], path
    end

    def test_leaves_small_held_logs_untouched
      path = write(File.join(@rails_log, 'autodev-stderr.log'), 'small')

      janitor.run

      assert_equal 5, File.size(path)
      assert_empty Dir.glob(File.join(@rails_log, 'autodev-stderr.log.*'))
    end

    def test_reports_counts
      write(File.join(@app_log, 'autodev', '2026-01-01.jsonl'), '{}', mtime: @old)
      write(File.join(@rails_log, 'autodev-stdout.log'), 'A' * 200)

      result = janitor.run

      assert_equal 1, result[:rotated].size
      assert_equal 1, result[:pruned]
    end
  end
end
