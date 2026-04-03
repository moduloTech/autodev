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

  def test_json_line_has_required_keys
    json = @logger.send(:build_json_line, 'INFO', 'test message', 'g/p', {})
    entry = JSON.parse(json)

    assert entry.key?('timestamp')
    assert_equal 'INFO', entry['level']
    assert_equal 'g/p', entry['project']
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

  def test_file_output_is_jsonl
    Dir.mktmpdir do |dir|
      @logger.configure(log_dir: dir, level: 'DEBUG')
      @logger.info('test log entry', project: 'g/p')
      @logger.close

      # Check global log
      global_files = Dir.glob(File.join(dir, 'autodev', '*.jsonl'))

      refute_empty global_files, 'Expected a .jsonl file in autodev/'
      line = File.readlines(global_files.first).first
      entry = JSON.parse(line)

      assert_equal 'test log entry', entry['message']

      # Check project log
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
end
