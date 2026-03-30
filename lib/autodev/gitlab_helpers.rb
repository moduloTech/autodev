# frozen_string_literal: true

require "time"

module GitlabHelpers
  module_function

  def build_gitlab_client(gitlab_url, token)
    raise ConfigError, "Missing GitLab API token (set GITLAB_API_TOKEN, use -t, or add gitlab_token to config)" unless token
    raise ConfigError, "Missing gitlab_url in config" unless gitlab_url

    Gitlab.client(endpoint: "#{gitlab_url}/api/v4", private_token: token)
  end

  def fetch_trigger_issues(client, project_path, trigger_label)
    client.issues(project_path, labels: trigger_label, state: "opened", per_page: 100)
  rescue Gitlab::Error::ResponseError => e
    raise AutodevError, "Failed to fetch issues for #{project_path}: #{e.message}"
  end

  def download_gitlab_images(text, gitlab_url:, project_path:, token:, dest_dir:)
    image_dir = File.join(dest_dir, ".autodev-images")
    downloaded = false

    result = text.gsub(/!\[([^\]]*)\]\((\/uploads\/[^)]+)\)(\{[^}]*\})?/) do
      alt = $1
      upload_path = $2
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
          http.use_ssl = (uri.scheme == "https")
          request = Net::HTTP::Get.new(uri.request_uri)
          request["PRIVATE-TOKEN"] = token
          response = http.request(request)

          if response.is_a?(Net::HTTPRedirection) && response["location"]
            uri = URI.parse(response["location"])
          else
            break
          end
        end

        if response.is_a?(Net::HTTPSuccess)
          body = response.body
          content_type = response["content-type"].to_s
          if body.nil? || body.empty? || !content_type.start_with?("image/")
            "[Image: #{filename} — format non supporté (#{content_type})]"
          else
            File.binwrite(local_path, body)
            "![#{alt}](#{local_path})"
          end
        else
          "[Image: #{filename} — download failed (#{response.code})]"
        end
      rescue StandardError
        "[Image: #{filename} — download failed]"
      end
    end

    result
  end

  def fetch_issue_context(client, project_path, issue_iid, gitlab_url: nil, token: nil, work_dir: nil)
    issue = client.issue(project_path, issue_iid)
    can_download = gitlab_url && token && work_dir

    lines = []
    lines << "# Issue ##{issue.iid}: #{issue.title}"
    lines << ""
    if issue.description && !issue.description.empty?
      desc = issue.description.to_s
      desc = download_gitlab_images(desc, gitlab_url: gitlab_url, project_path: project_path, token: token, dest_dir: work_dir) if can_download
      lines << desc
    end
    lines << ""

    begin
      notes = client.issue_notes(project_path, issue_iid, per_page: 100)
      user_notes = notes.select { |n| !n.system && !n.body.to_s.include?("**autodev**") }
      if user_notes.any?
        lines << "## Comments"
        lines << ""
        user_notes.each do |note|
          lines << "### #{note.author&.name || "Unknown"} (#{note.created_at})"
          body = note.body.to_s
          body = download_gitlab_images(body, gitlab_url: gitlab_url, project_path: project_path, token: token, dest_dir: work_dir) if can_download
          lines << body
          lines << ""
        end
      end
    rescue Gitlab::Error::ResponseError
      # Non-fatal: proceed without comments
    end

    begin
      links = client.issue_links(project_path, issue_iid)
      if links.any?
        lines << "## Related issues"
        lines << ""
        links.each do |link|
          lines << "- ##{link.iid}: #{link.title} (#{link.state})"
        end
        lines << ""
      end
    rescue Gitlab::Error::ResponseError, NoMethodError
      # Non-fatal: some GitLab versions don't support this
    end

    lines.join("\n")
  end

  def clarification_answered?(client, project_path, issue_iid, requested_at)
    return true unless requested_at

    threshold = Time.parse(requested_at.to_s)
    notes = client.issue_notes(project_path, issue_iid, per_page: 100)
    notes.any? do |note|
      !note.system &&
        Time.parse(note.created_at.to_s) > threshold &&
        !note.body.to_s.include?("**autodev**")
    end
  rescue Gitlab::Error::ResponseError
    false
  end
end
