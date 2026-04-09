# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'tmpdir'

class ScreenshotUploaderTest < Minitest::Test
  PROJECT = 'g/p'
  IID = 99

  def setup
    @dir = ScreenshotUploader.screenshot_dir(PROJECT, IID)
    FileUtils.mkdir_p(@dir)
    @logger = StubLogger.new
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_screenshot_dir_format
    result = ScreenshotUploader.screenshot_dir('group/project', 42)

    assert_equal '/tmp/autodev_screenshots_group_project_42', result
  end

  def test_process_skips_when_no_index
    FileUtils.rm_rf(@dir)
    client = StubClient.new

    ScreenshotUploader.process(client: client, project_path: PROJECT, iid: IID, logger: @logger)

    assert_empty client.uploaded_files
  end

  def test_process_skips_when_empty_index
    write_index('screenshots' => [])
    client = StubClient.new

    ScreenshotUploader.process(client: client, project_path: PROJECT, iid: IID, logger: @logger)

    assert_empty client.uploaded_files
  end

  def test_process_uploads_and_posts_comment
    write_index('screenshots' => [screenshot_entry('home', '/', 'Home page')])
    write_screenshot('home')
    client = StubClient.new

    ScreenshotUploader.process(client: client, project_path: PROJECT, iid: IID, logger: @logger)

    assert_equal 1, client.uploaded_files.size
    assert_equal 1, client.posted_notes.size
    assert_includes client.posted_notes.first[:body], 'Home page'
  end

  def test_process_skips_missing_screenshot_file
    write_index('screenshots' => [screenshot_entry('missing', '/x', 'Missing')])
    client = StubClient.new

    ScreenshotUploader.process(client: client, project_path: PROJECT, iid: IID, logger: @logger)

    assert_empty client.uploaded_files
    assert_empty client.posted_notes
  end

  def test_mr_fix_context_in_comment
    write_index('screenshots' => [screenshot_entry('fix', '/fix', 'Fix page', 'mr_fix')])
    write_screenshot('fix')
    client = StubClient.new

    ScreenshotUploader.process(client: client, project_path: PROJECT, iid: IID, logger: @logger)

    assert_includes client.posted_notes.first[:body], 'correction suite a review'
  end

  def test_cleanup_removes_directory
    write_index('screenshots' => [screenshot_entry('home', '/', 'Home')])
    write_screenshot('home')
    client = StubClient.new

    ScreenshotUploader.process(client: client, project_path: PROJECT, iid: IID, logger: @logger)

    refute Dir.exist?(@dir)
  end

  private

  def screenshot_entry(key, url, description, context = 'implementation')
    { 'key' => key, 'url' => url, 'description' => description, 'context' => context }
  end

  def write_index(data)
    File.write(File.join(@dir, 'index.json'), JSON.generate(data))
  end

  def write_screenshot(key)
    File.binwrite(File.join(@dir, "#{key}.png"), 'fake png data')
  end

  # Minimal stub client for GitLab API calls used by ScreenshotUploader.
  class StubClient
    attr_reader :uploaded_files, :posted_notes

    UploadResult = Struct.new(:markdown)

    def initialize
      @uploaded_files = []
      @posted_notes = []
    end

    def upload_file(project_path, file_path)
      @uploaded_files << { project_path: project_path, file_path: file_path }
      UploadResult.new("![screenshot](/uploads/fake/#{File.basename(file_path)})")
    end

    def create_issue_note(project_path, iid, body)
      @posted_notes << { project_path: project_path, iid: iid, body: body }
    end
  end
end
