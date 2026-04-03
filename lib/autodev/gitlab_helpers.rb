# frozen_string_literal: true

require 'time'

# Shared helpers for interacting with the GitLab API.
module GitlabHelpers
  module_function

  def build_gitlab_client(gitlab_url, token)
    unless token
      raise ConfigError,
            'Missing GitLab API token (set GITLAB_API_TOKEN, use -t, or add gitlab_token to config)'
    end
    raise ConfigError, 'Missing gitlab_url in config' unless gitlab_url

    Gitlab.client(endpoint: "#{gitlab_url}/api/v4", private_token: token)
  end

  def fetch_trigger_issues(client, project_path, trigger_label)
    client.issues(project_path, labels: trigger_label, state: 'opened', per_page: 100)
  rescue Gitlab::Error::ResponseError => e
    raise AutodevError, "Failed to fetch issues for #{project_path}: #{e.message}"
  end

  def download_gitlab_images(text, gitlab_url:, project_path:, token:, dest_dir:)
    state = { image_dir: File.join(dest_dir, '.autodev-images'), downloaded: false }
    opts = { gitlab_url: gitlab_url, project_path: project_path, token: token }

    text.gsub(%r{!\[([^\]]*)\]\((/uploads/[^)]+)\)(\{[^\}]*\})?}) do
      ImageDownloader.replace_reference(::Regexp.last_match(1), ::Regexp.last_match(2), opts, state)
    end
  end

  def fetch_issue_context(client, project_path, issue_iid, **opts)
    issue = client.issue(project_path, issue_iid)
    img_opts = ImageDownloader.download_opts(opts, project_path)

    lines = IssueFormatter.build_header(issue, img_opts)
    IssueFormatter.append_comments(lines, client, project_path, issue_iid, img_opts)
    IssueFormatter.append_links(lines, client, project_path, issue_iid)

    lines.join("\n")
  end

  # Fetch all MR discussions (resolved and unresolved) formatted as markdown.
  def fetch_mr_discussions_context(client, project_path, mr_iid)
    discussions = client.merge_request_discussions(project_path, mr_iid)
    return '' if discussions.empty?

    lines = ['## MR Discussions', '']
    discussions.each { |d| DiscussionFormatter.format(lines, d) }

    lines.join("\n")
  rescue Gitlab::Error::ResponseError
    ''
  end

  # Fetch full context: issue (title, body, comments) + MR discussions (if mr_iid provided).
  def fetch_full_context(client, project_path, issue_iid, **opts)
    mr_iid = opts.delete(:mr_iid)
    context = fetch_issue_context(client, project_path, issue_iid, **opts)

    if mr_iid
      mr_discussions = fetch_mr_discussions_context(client, project_path, mr_iid)
      context = "#{context}\n\n#{mr_discussions}" unless mr_discussions.empty?
    end

    context
  end

  # Write the context file in /tmp so it stays outside the git work tree
  # and cannot be accidentally committed by danger-claude.
  def write_context_file(_work_dir, branch_name, content)
    path = context_file_path(branch_name)
    File.write(path, content)
    path
  end

  # Returns the context file path for a given branch (always in /tmp).
  def context_file_path(branch_name)
    filename = branch_name.to_s.sub(%r{^autodev/}, '')
    File.join('/tmp', "#{filename}.md")
  end

  # Delete the context file if it exists.
  def cleanup_context_file(_work_dir, branch_name)
    path = context_file_path(branch_name)
    FileUtils.rm_f(path)
  end

  def clarification_answered?(client, project_path, issue_iid, requested_at)
    return true unless requested_at

    threshold = Time.parse(requested_at.to_s)
    notes = client.issue_notes(project_path, issue_iid, per_page: 100)
    notes.any? do |note|
      !note.system &&
        Time.parse(note.created_at.to_s) > threshold &&
        !note.body.to_s.include?('**autodev**')
    end
  rescue Gitlab::Error::ResponseError
    false
  end

  # Image downloading helpers.
  module ImageDownloader
    module_function

    # Returns an options hash for image downloading, or nil if not available.
    def download_opts(opts, project_path)
      return nil unless opts[:gitlab_url] && opts[:token] && opts[:work_dir]

      { gitlab_url: opts[:gitlab_url], token: opts[:token], project_path: project_path, dest_dir: opts[:work_dir] }
    end

    # Optionally downloads images in the given text.
    def maybe_download(text, img_opts)
      return text unless img_opts

      GitlabHelpers.download_gitlab_images(text, **img_opts)
    end

    # Replace a single image markdown reference with a local path or error placeholder.
    def replace_reference(alt, upload_path, opts, state)
      url = "#{opts[:gitlab_url]}/#{opts[:project_path]}#{upload_path}"
      filename = File.basename(upload_path)
      local_path = File.join(state[:image_dir], filename)

      ensure_dir(state)
      download_and_save(url, opts[:token], local_path, alt, filename)
    rescue StandardError => e
      "[Image: #{filename} -- download failed: #{e.class}: #{e.message}]"
    end

    # Create the image directory on first use.
    def ensure_dir(state)
      return if state[:downloaded]

      FileUtils.mkdir_p(state[:image_dir])
      state[:downloaded] = true
    end

    # Download an image following redirects, save it, and return the markdown reference.
    def download_and_save(url, token, local_path, alt, filename)
      response = http_get_with_redirects(url, token)

      return "[Image: #{filename} -- download failed (#{response.code})]" unless response.is_a?(Net::HTTPSuccess)

      validate_and_write(response, local_path, alt, filename)
    end

    # Perform an HTTP GET following up to 3 redirects.
    def http_get_with_redirects(url, token)
      uri = URI.parse(url)
      response = nil
      3.times do
        response = single_get(uri, token)
        break unless response.is_a?(Net::HTTPRedirection) && response['location']

        uri = URI.parse(response['location'])
      end
      response
    end

    # Perform a single HTTP GET request.
    def single_get(uri, token)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      request = Net::HTTP::Get.new(uri.request_uri)
      request['PRIVATE-TOKEN'] = token
      http.request(request)
    end

    # Validate image content type and write to disk.
    def validate_and_write(response, local_path, alt, filename)
      body = response.body
      content_type = response['content-type'].to_s
      if body.nil? || body.empty? || !content_type.start_with?('image/')
        return "[Image: #{filename} -- format non support\u00E9 (#{content_type})]"
      end

      File.binwrite(local_path, body)
      "![#{alt}](#{local_path})"
    end
  end

  # Issue context formatting helpers.
  module IssueFormatter
    module_function

    # Build the header section (title + description) for an issue.
    def build_header(issue, img_opts)
      lines = ["# Issue ##{issue.iid}: #{issue.title}", '']
      if issue.description && !issue.description.empty?
        lines << ImageDownloader.maybe_download(issue.description.to_s, img_opts)
      end
      lines << ''
      lines
    end

    # Append user comments to the lines array.
    def append_comments(lines, client, project_path, issue_iid, img_opts)
      notes = client.issue_notes(project_path, issue_iid, per_page: 100)
      user_notes = notes.reject { |n| n.system || n.body.to_s.include?('**autodev**') }
      return unless user_notes.any?

      lines << '## Comments'
      lines << ''
      user_notes.each { |note| append_single_comment(lines, note, img_opts) }
    rescue Gitlab::Error::ResponseError
      # Non-fatal: proceed without comments
    end

    # Format and append a single comment note.
    def append_single_comment(lines, note, img_opts)
      lines << "### #{note.author&.name || 'Unknown'} (#{note.created_at})"
      lines << ImageDownloader.maybe_download(note.body.to_s, img_opts)
      lines << ''
    end

    # Append related issue links to the lines array.
    def append_links(lines, client, project_path, issue_iid)
      links = client.issue_links(project_path, issue_iid)
      return unless links.any?

      lines << '## Related issues'
      lines << ''
      links.each { |link| lines << "- ##{link.iid}: #{link.title} (#{link.state})" }
      lines << ''
    rescue Gitlab::Error::ResponseError, NoMethodError
      # Non-fatal: some GitLab versions don't support this
    end
  end

  # MR discussion formatting helpers.
  module DiscussionFormatter
    module_function

    # Format a single discussion into markdown lines.
    def format(lines, discussion)
      notes = discussion.notes
      return unless notes&.any?

      status = resolve_status(notes)
      notes.each_with_index { |note, idx| format_note(lines, note, idx, status) }
    end

    # Determine the resolution status of a discussion.
    def resolve_status(notes)
      resolvable = notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
      return 'comment' unless resolvable.any?

      resolvable.all? { |n| n.respond_to?(:resolved) && n.resolved } ? 'resolved' : 'unresolved'
    end

    # Format a single note within a discussion.
    def format_note(lines, note, idx, status)
      author = note.author&.name || 'Unknown'
      lines << if idx.zero?
                 "### [#{status}] #{author} (#{note.created_at})"
               else
                 "#### #{author} (#{note.created_at})"
               end

      append_position(lines, note) if idx.zero?

      lines << ''
      lines << note.body.to_s
      lines << ''
    end

    # Append file position info for a discussion-starting note.
    def append_position(lines, note)
      return unless note.respond_to?(:position) && note.position

      pos = note.position
      file_path = pos_field(pos, :new_path)
      new_line = pos_field(pos, :new_line)
      lines << "Fichier: `#{file_path}`#{" (ligne #{new_line})" if new_line}" if file_path
    end

    # Extract a field from a position object (supports both method calls and hash access).
    def pos_field(pos, field)
      if pos.respond_to?(field)
        pos.public_send(field)
      elsif pos.is_a?(Hash)
        pos[field.to_s] || pos[field]
      end
    end
  end
end
