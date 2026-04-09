# frozen_string_literal: true

require 'json'

# Reads screenshot index from the shared directory, uploads each file to GitLab,
# and posts a comment on the issue with all screenshots and their context.
module ScreenshotUploader
  SCREENSHOT_DIR_PREFIX = '/tmp/autodev_screenshots'

  module_function

  # Returns the screenshot directory path for a given project and issue.
  def screenshot_dir(project_path, iid)
    "#{SCREENSHOT_DIR_PREFIX}_#{project_path.gsub('/', '_')}_#{iid}"
  end

  # Process screenshots if an index exists. Non-fatal: logs errors and continues.
  def process(client:, project_path:, iid:, logger:)
    dir = screenshot_dir(project_path, iid)
    return unless File.exist?(File.join(dir, 'index.json'))

    do_process(dir, client, project_path, iid, logger)
  rescue StandardError => e
    logger.error("Screenshot upload failed for ##{iid}: #{e.message}", project: project_path)
  ensure
    cleanup(dir)
  end

  def do_process(dir, client, project_path, iid, logger)
    entries = read_index(File.join(dir, 'index.json'), logger)
    return if entries.empty?

    markdown = upload_and_format(entries, dir, client, project_path, logger)
    post_comment(client, project_path, iid, markdown, logger) unless markdown.empty?
  end
  private_class_method :do_process

  def read_index(index_path, logger)
    data = JSON.parse(File.read(index_path))
    entries = data['screenshots']
    unless entries.is_a?(Array) && entries.any?
      logger.debug('Screenshot index is empty or malformed, skipping', project: '')
      return []
    end
    entries
  end
  private_class_method :read_index

  def upload_and_format(entries, dir, client, project_path, logger)
    results = entries.filter_map { |entry| upload_single(entry, dir, client, project_path, logger) }
    return '' if results.empty?

    format_comment(results)
  end
  private_class_method :upload_and_format

  def upload_single(entry, dir, client, project_path, logger)
    key = entry['key']
    file_path = File.join(dir, "#{key}.png")
    return log_missing(file_path, logger, project_path) unless File.exist?(file_path)

    response = client.upload_file(project_path, file_path)
    { markdown: response.markdown, description: entry['description'], context: entry['context'], url: entry['url'] }
  rescue Gitlab::Error::ResponseError => e
    logger.error("Failed to upload screenshot #{key}: #{e.message}", project: project_path)
    nil
  end
  private_class_method :upload_single

  def log_missing(file_path, logger, project_path)
    logger.debug("Screenshot file missing: #{file_path}, skipping", project: project_path)
    nil
  end
  private_class_method :log_missing

  def format_comment(results)
    lines = ["**autodev** (v#{Autodev::VERSION}) — Captures d'ecran\n"]
    results.each { |r| format_single_result(lines, r) }
    lines.join("\n")
  end
  private_class_method :format_comment

  def format_single_result(lines, result)
    desc = result[:description]
    desc = "#{desc} *(correction suite a review)*" if result[:context] == 'mr_fix'
    lines << "### #{desc}"
    lines << "Page : `#{result[:url]}`" if result[:url]
    lines << ''
    lines << result[:markdown]
    lines << ''
  end
  private_class_method :format_single_result

  def post_comment(client, project_path, iid, markdown, logger)
    count = markdown.count('![')
    client.create_issue_note(project_path, iid, markdown)
    logger.info("Posted #{count} screenshot(s) on issue ##{iid}", project: project_path)
  rescue Gitlab::Error::ResponseError => e
    logger.error("Failed to post screenshot comment on ##{iid}: #{e.message}", project: project_path)
  end
  private_class_method :post_comment

  def cleanup(dir)
    FileUtils.rm_rf(dir)
  end
  private_class_method :cleanup
end
