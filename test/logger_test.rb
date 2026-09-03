# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'

class LoggerTest < Minitest::Test
  def setup
    @logger = AppLogger.new(pastel: FakePastel.new)
  end

  def teardown
    @logger.close
  end

  def test_json_line_has_timestamp
    json = @logger.send(:build_json_line, 'INFO', 'test message', 'g/p', {})
    entry = JSON.parse(json)

    assert entry.key?('timestamp')
  end

  def test_json_line_has_level
    json = @logger.send(:build_json_line, 'INFO', 'test message', 'g/p', {})
    entry = JSON.parse(json)

    assert_equal 'INFO', entry['level']
  end

  def test_json_line_has_project
    json = @logger.send(:build_json_line, 'INFO', 'test message', 'g/p', {})
    entry = JSON.parse(json)

    assert_equal 'g/p', entry['project']
  end

  def test_json_line_has_message
    json = @logger.send(:build_json_line, 'INFO', 'test message', 'g/p', {})
    entry = JSON.parse(json)

    assert_equal 'test message', entry['message']
  end

  def test_json_line_includes_structured_fields
    json = @logger.send(:build_json_line, 'INFO', 'msg', 'g/p',
                        { issue_iid: 42, state: 'implementing', event: 'spec_clear' })
    entry = JSON.parse(json)

    assert_equal 42, entry['issue_iid']
    assert_equal 'implementing', entry['state']
    assert_equal 'spec_clear', entry['event']
  end

  def test_json_line_includes_extra_context
    json = @logger.send(:build_json_line, 'INFO', 'msg', nil,
                        { issue_iid: 1, foo: 'bar', baz: 123 })
    entry = JSON.parse(json)

    assert_equal 'bar', entry.dig('context', 'foo')
    assert_equal 123, entry.dig('context', 'baz')
  end

  def test_json_line_omits_context_when_empty
    json = @logger.send(:build_json_line, 'INFO', 'msg', nil, {})
    entry = JSON.parse(json)

    refute entry.key?('context')
  end

  def test_debug_filtered_at_info_level
    @logger.configure(log_dir: Dir.mktmpdir, level: 'INFO')
    out, _err = capture_io { @logger.debug('should not appear') }

    assert_empty out
  end

  def test_error_goes_to_stderr
    _out, err = capture_io { @logger.error('boom') }

    assert_includes err, 'boom'
  end

  def test_info_goes_to_stdout
    out, _err = capture_io { @logger.info('hello') }

    assert_includes out, 'hello'
  end

  def test_multiline_truncated_on_console
    out, _err = capture_io { @logger.info("first line\nsecond line\nthird line") }

    assert_includes out, 'first line'
    refute_includes out, 'second line'
  end

  def test_file_output_writes_global_jsonl
    Dir.mktmpdir do |dir|
      @logger.configure(log_dir: dir, level: 'DEBUG')
      @logger.info('test log entry', project: 'g/p')
      @logger.close

      global_files = Dir.glob(File.join(dir, 'autodev', '*.jsonl'))

      refute_empty global_files, 'Expected a .jsonl file in autodev/'
      entry = JSON.parse(File.readlines(global_files.first).first)

      assert_equal 'test log entry', entry['message']
    end
  end

  def test_file_output_writes_project_jsonl
    Dir.mktmpdir do |dir|
      @logger.configure(log_dir: dir, level: 'DEBUG')
      @logger.info('test log entry', project: 'g/p')
      @logger.close

      project_files = Dir.glob(File.join(dir, 'g_p', '*.jsonl'))

      refute_empty project_files, 'Expected a .jsonl file in g_p/'
    end
  end

  def test_accepts_extra_context_kwargs
    out, _err = capture_io do
      @logger.info('msg', project: 'g/p', issue_iid: 42, state: 'implementing')
    end

    assert_includes out, 'msg'
  end

  # Autodev #92: the supervisor's own lifecycle line ("spawned rails-server",
  # "stopping solid-queue", …) went through $stdout.puts with no sync flag —
  # block-buffered whenever stdout isn't a TTY, which launchd's captured
  # stdout/stderr never is. A boot that died right after logging one line
  # could lose it, which is exactly what left 39 of 63 production boots that
  # ended short with no account of themselves in the log at all.
  def test_syncs_stdout_so_a_lifecycle_line_survives_an_abrupt_death
    $stdout.sync = false

    AppLogger.new(pastel: FakePastel.new)

    assert $stdout.sync, 'AppLogger.new must sync $stdout — buffered output is lost if the process dies mid-line'
  ensure
    $stdout.sync = true
  end
end
