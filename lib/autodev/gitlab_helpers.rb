# frozen_string_literal: true

require 'time'

module GitlabHelpers
  module_function

  def build_gitlab_client(gitlab_url, token)
    raise ConfigError, 
'Missing GitLab API token (set GITLAB_API_TOKEN, use -t, or add gitlab_token to config)' unless token
    raise ConfigError, 'Missing gitlab_url in config' unless gitlab_url

    Gitlab.client(endpoint: "#{gitlab_url}/api/v4", private_token: token)
  end

  def fetch_trigger_issues(client, project_path, trigger_label)
    client.issues(project_path, labels: trigger_label, state: 'opened', per_page: 100)
  rescue Gitlab::Error::ResponseError => e
    raise AutodevError, "Failed to fetch issues for #{project_path}: #{e.message}"
  end

  def download_gitlab_images(text, gitlab_url:, project_path:, token:, dest_dir:)
    image_dir = File.join(dest_dir, '.autodev-images')
    downloaded = false

    result = text.gsub(/!\[([^\]]*)\]\((\/uploads\/[^)]+)\)(\{[^}]*\})?/) do
      alt = ::Regexp.last_match(1)
      upload_path = ::Regexp.last_match(2)
      url = "#{gitlab_url}/#{project_path}#{upload_path}"
      filename = File.basename(upload_path)
      local_path = File.join(image_dir, filename)

      begin
        unless downloaded
          FileUtils.mkdir_p(image_dir)
          downloaded = true
        end

        uri = URI.parse(url)
        response = nil
        3.times do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == 'https')
          request = Net::HTTP::Get.new(uri.request_uri)
          request['PRIVATE-TOKEN'] = token
          response = http.request(request)

          break unless response.is_a?(Net::HTTPRedirection) && response['location']
            uri = URI.parse(response['location'])
          
            
          
        end

        if response.is_a?(Net::HTTPSuccess)
          body = response.body
          content_type = response['content-type'].to_s
          if body.nil? || body.empty? || !content_type.start_with?('image/')
            "[Image: #{filename} — format non supporté (#{content_type})]"
          else
            File.binwrite(local_path, body)
            "![#{alt}](#{local_path})"
          end
        else
          "[Image: #{filename} — download failed (#{response.code})]"
        end
      rescue StandardError => e
        "[Image: #{filename} — download failed: #{e.class}: #{e.message}]"
      end
    end

    result
  end

  def fetch_issue_context(client, project_path, issue_iid, gitlab_url: nil, token: nil, work_dir: nil)
    issue = client.issue(project_path, issue_iid)
    can_download = gitlab_url && token && work_dir

    lines = []
    lines << "# Issue ##{issue.iid}: #{issue.title}"
    lines << ''
    if issue.description && !issue.description.empty?
      desc = issue.description.to_s
      desc = download_gitlab_images(desc, gitlab_url: gitlab_url, project_path: project_path, token: token, 
dest_dir: work_dir) if can_download
      lines << desc
    end
    lines << ''

    begin
      notes = client.issue_notes(project_path, issue_iid, per_page: 100)
      user_notes = notes.select { |n| !n.system && !n.body.to_s.include?('**autodev**') }
      if user_notes.any?
        lines << '## Comments'
        lines << ''
        user_notes.each do |note|
          lines << "### #{note.author&.name || 'Unknown'} (#{note.created_at})"
          body = note.body.to_s
          body = download_gitlab_images(body, gitlab_url: gitlab_url, project_path: project_path, token: token, 
dest_dir: work_dir) if can_download
          lines << body
          lines << ''
        end
      end
    rescue Gitlab::Error::ResponseError
      # Non-fatal: proceed without comments
    end

    begin
      links = client.issue_links(project_path, issue_iid)
      if links.any?
        lines << '## Related issues'
        lines << ''
        links.each do |link|
          lines << "- ##{link.iid}: #{link.title} (#{link.state})"
        end
        lines << ''
      end
    rescue Gitlab::Error::ResponseError, NoMethodError
      # Non-fatal: some GitLab versions don't support this
    end

    lines.join("\n")
  end

  # Fetch all MR discussions (resolved and unresolved) formatted as markdown.
  def fetch_mr_discussions_context(client, project_path, mr_iid)
    discussions = client.merge_request_discussions(project_path, mr_iid)
    return '' if discussions.empty?

    lines = []
    lines << '## MR Discussions'
    lines << ''

    discussions.each do |discussion|
      notes = discussion.notes
      next unless notes&.any?

      resolvable = notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
      resolved = resolvable.any? && resolvable.all? { |n| n.respond_to?(:resolved) && n.resolved }
      status = if resolvable.any?
resolved ? 'resolved' : 'unresolved'
else
'comment'
end

      notes.each_with_index do |note, idx|
        author = note.author&.name || 'Unknown'
        prefix = idx.zero? ? "### [#{status}] #{author} (#{note.created_at})" : "#### #{author} (#{note.created_at})"
        lines << prefix

        if idx.zero? && note.respond_to?(:position) && note.position
          pos = note.position
          file_path = if pos.respond_to?(:new_path)
pos.new_path
else
(pos.is_a?(Hash) ? (pos['new_path'] || pos[:new_path]) : nil)
end
          new_line = if pos.respond_to?(:new_line)
pos.new_line
else
(pos.is_a?(Hash) ? (pos['new_line'] || pos[:new_line]) : nil)
end
          lines << "Fichier: `#{file_path}`#{" (ligne #{new_line})" if new_line}" if file_path
        end

        lines << ''
        lines << note.body.to_s
        lines << ''
      end
    end

    lines.join("\n")
  rescue Gitlab::Error::ResponseError
    ''
  end

  # Fetch full context: issue (title, body, comments) + MR discussions (if mr_iid provided).
  def fetch_full_context(client, project_path, issue_iid, mr_iid: nil, gitlab_url: nil, token: nil, work_dir: nil)
    context = fetch_issue_context(client, project_path, issue_iid, gitlab_url: gitlab_url, token: token, 
work_dir: work_dir)

    if mr_iid
      mr_discussions = fetch_mr_discussions_context(client, project_path, mr_iid)
      context = "#{context}\n\n#{mr_discussions}" unless mr_discussions.empty?
    end

    context
  end

  # Write the context file at the clone root, named after the branch (without autodev/ prefix).
  def write_context_file(work_dir, branch_name, content)
    path = context_file_path(work_dir, branch_name)
    File.write(path, content)
    path
  end

  # Returns the context file path for a given branch.
  def context_file_path(work_dir, branch_name)
    filename = branch_name.to_s.sub(%r{^autodev/}, '')
    File.join(work_dir, "#{filename}.md")
  end

  # Delete the context file if it exists.
  def cleanup_context_file(work_dir, branch_name)
    path = context_file_path(work_dir, branch_name)
    File.delete(path) if File.exist?(path)
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
end
