# frozen_string_literal: true

require 'time'
require 'openssl'
require 'socket'
require 'timeout'
require 'net/protocol'

# Shared helpers for interacting with the GitLab API.
module GitlabHelpers
  # Every way a GitLab call can fail to produce an answer (Autodev #62, third
  # round). The first entry is GitLab answering with a status it could not honour;
  # the rest are the request never completing at all — and the point of the list is
  # that they are the *same event* for every caller, while none of them is a
  # `Gitlab::Error::ResponseError`.
  #
  # The gap was measured on this repository's own review path: a VPN hiccup during
  # `SkillReviewer` reached `rescue StandardError => e; raise ImplementationError`,
  # i.e. it was recorded as a review *failure*, five of which give the request up
  # under `review_failures_exhausted` and hand the ticket back to its author. The
  # comment above that rescue already said the split existed so an outage would not
  # be reclassified; it only ever covered HTTP.
  #
  # What is deliberately **not** here is anything a caller could have caused:
  # `NoMethodError`, `ArgumentError`, `NameError`, `TypeError` and every other
  # programming error keeps travelling as itself, to a stack trace. Reading a bug
  # in this repository as "GitLab is down" is the same lie in the other direction,
  # and it is the one a `rescue StandardError` here would tell.
  #
  # `Timeout::Error` covers `Net::OpenTimeout` and `Net::ReadTimeout`, which
  # subclass it; `EOFError` is the peer hanging up mid-response, which `net/http`
  # raises rather than translating; and `SystemCallError` is the whole `Errno::*`
  # family — `ECONNRESET`, `EHOSTUNREACH`, `EPIPE`, `ETIMEDOUT` and the rest — read
  # as one entry rather than as a list somebody has to keep complete. It is broad,
  # and it is exactly as broad as the block: `answer` wraps a GitLab client call
  # and nothing else, so an operating-system error raised under it came from the
  # socket.
  TRANSPORT_ERRORS = [Gitlab::Error::ResponseError, SystemCallError, Timeout::Error,
                      SocketError, OpenSSL::SSL::SSLError, EOFError].freeze

  module_function

  # Delegated to `HumanActivity`, which owns the question — see that file. Kept
  # reachable here because `GitlabHelpers` is where every caller already asks.
  def human_comment_since?(...) = HumanActivity.human_comment_since?(...)
  def human_mr_comment_since?(...) = HumanActivity.human_mr_comment_since?(...)

  # Read a field from a GitLab API value whatever its shape: the gitlab gem
  # returns objects with attribute readers, while tests and some paths pass raw
  # Hashes (string- or symbol-keyed). Reader wins, then a string key, then a
  # symbol key. Canonical replacement for the ~half-dozen
  # `x.respond_to?(:f) ? x.f : x['f']` copies that had drifted apart (some tried
  # symbol keys, some only string). Falsey values are preserved (no `||`).
  def field(obj, name)
    return obj.public_send(name) if obj.respond_to?(name)
    return unless obj.respond_to?(:[])
    return obj[name.to_s] if !obj.respond_to?(:key?) || obj.key?(name.to_s)

    obj[name.to_sym]
  end

  # The single conversion point from "GitLab did not answer" to "this unit of
  # work cannot conclude" (Autodev #62). Wrap a read whose value a caller will
  # act on:
  #
  #   GitlabHelpers.answer(:pipeline_jobs) { @client.pipeline_jobs(path, id) }
  #
  # There is deliberately no variant that returns a fallback. The rule this
  # encodes is that a failed read has no representation as data — see
  # `ApiUnavailableError` for why the neutral values it replaces were worse than
  # the outage they hid. A *write* whose failure is not a verdict (retrigger a
  # pipeline, resolve a thread) is a different case and does not belong here.
  #
  # A read left bare, with no rescue at all, already behaves correctly: the
  # failure reaches the same boundary rescue. This wrapper adds the name of the
  # endpoint to the log line, and — since the third round — puts the failures that
  # are *not* HTTP into the same family as the ones that are: see
  # `TRANSPORT_ERRORS` for why a bare `Errno::ECONNRESET` was the more dangerous
  # half, and for what stays outside on purpose.
  #
  # *Which* failure it was is `GitlabFailure`'s question, not this one's (Autodev
  # #95). This owns the rule — a failed call has no representation as data — and
  # that owns the reading: an outage, or GitLab answering that the request cannot
  # succeed as formed. The second is bounded rather than waited on, because
  # re-sending it produces the same answer for ever.
  def answer(what)
    yield
  rescue *TRANSPORT_ERRORS => e
    raise GitlabFailure.classify(what, e)
  end

  # The single place a URL + token become a Gitlab::Client (Autodev #96 — 12
  # call sites, confirmed by grep in the design spec). Wrapping the return
  # value here, rather than at each call site, is what instruments every
  # request — read and write — without any of them changing.
  def build_gitlab_client(gitlab_url, token)
    unless token
      raise ConfigError,
            'Missing GitLab API token (set GITLAB_API_TOKEN, use -t, or add gitlab_token to config)'
    end
    raise ConfigError, 'Missing gitlab_url in config' unless gitlab_url

    GitlabRequestCounter.new(Gitlab.client(endpoint: "#{gitlab_url}/api/v4", private_token: token))
  end

  def fetch_assignee_issues(client, project_path, labels_todo, assignee_id)
    issues = client.issues(project_path, assignee_id: assignee_id, state: 'opened', per_page: 100).auto_paginate
    todo_set = (labels_todo || []).to_set
    issues.select { |i| (i.labels || []).any? { |l| todo_set.include?(l) } }
  rescue Gitlab::Error::ResponseError => e
    raise AutodevError, "Failed to fetch issues for #{project_path}: #{e.message}"
  end

  def current_user_id(client)
    @current_user_id ||= client.user.id
  end

  def download_gitlab_images(text, gitlab_url:, project_path:, token:, dest_dir:)
    state = { image_dir: File.join(dest_dir, '.autodev-images'), downloaded: false }
    opts = { gitlab_url: gitlab_url, project_path: project_path, token: token }

    text.gsub(%r{!\[([^\]]*)\]\((/uploads/[^)]+)\)(\{[^\}]*\})?}) do
      ImageDownloader.replace_reference(::Regexp.last_match(1), ::Regexp.last_match(2), opts, state)
    end
  end

  # The prompt context is a read like any other (Autodev #67). It used to be the
  # one exception on the #62 rule's own tree: `client.issue` bare, under the
  # `rescue StandardError` of `attempt_fix` / `execute_fix_cycle`, so a GitLab
  # blip while assembling a prompt was charged to the correction — `error`, a
  # comment blaming the fix, a retry spent. Wrapped, it raises and the poll ends
  # at its own boundary with the row untouched, exactly like the failed-job list
  # and the unresolved-thread list above it.
  def fetch_issue_context(client, project_path, issue_iid, **opts)
    issue = answer(:issue) { client.issue(project_path, issue_iid) }
    img_opts = ImageDownloader.download_opts(opts, project_path)

    lines = IssueFormatter.build_header(issue, img_opts)
    IssueFormatter.append_comments(lines, client, project_path, issue_iid, img_opts)
    IssueFormatter.append_links(lines, client, project_path, issue_iid)

    lines.join("\n")
  end

  # Fetch all MR discussions (resolved and unresolved) formatted as markdown.
  #
  # `''` used to stand in for a failed read (Autodev #67 removed it): the review
  # history is the substance of a fix prompt, and an empty section is
  # indistinguishable from an MR nobody has commented on. The one caller that
  # needs this — `fetch_full_context` — is now all-or-nothing: it either produces
  # the real context or aborts the unit of work.
  def fetch_mr_discussions_context(client, project_path, mr_iid)
    discussions = answer(:mr_discussions_context) do
      client.merge_request_discussions(project_path, mr_iid, per_page: 100).auto_paginate
    end
    return '' if discussions.empty?

    lines = ['## MR Discussions', '']
    discussions.each { |d| DiscussionFormatter.format(lines, d) }

    lines.join("\n")
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
  # Slashes in branch names are replaced with underscores to avoid creating subdirectories.
  def context_file_path(branch_name)
    filename = branch_name.to_s.sub(%r{^autodev/}, '').tr('/', '_')
    File.join('/tmp', "#{filename}.md")
  end

  # Delete the context file if it exists.
  def cleanup_context_file(_work_dir, branch_name)
    path = context_file_path(branch_name)
    FileUtils.rm_f(path)
  end

  def clarification_answered?(client, project_path, issue_iid, requested_at)
    return true unless requested_at

    human_comment_since?(client, project_path, issue_iid, requested_at)
  end

  # True when a human (not autodev, not a system note) posted a comment on the
  # issue strictly after `since`. Used both to detect a clarification answer and
  # to detect recette-KO feedback left on a delivered ticket (bug #32).
  #
  # It used to answer an API error with `false`, i.e. "nobody replied" (Autodev
  # #67). At one of its two call sites that is a verdict: `open_mr_destination`
  # turns `false` into `:pipeline_check`, the path that never reads issue
  # comments, so the identical MR is re-delivered and the human's feedback is
  # never seen — the exact bug #32 this predicate exists to prevent. `false` is
  # returned only for a question that was not asked (`since` nil); a question
  # GitLab did not answer raises, and each caller decides at its own boundary.

  # Image downloading helpers.
  module ImageDownloader
    module_function

    # GitLab serves a project's `/uploads/<secret>/<file>` path **to a browser
    # session only**: a PRIVATE-TOKEN request gets 200 + the sign-in HTML page,
    # not the image (measured against source.modulotech.fr, 2026-08-06). The
    # token-authenticated equivalent is the API endpoint below, which answered
    # 200 + the real bytes for the same upload.
    #
    # `upload_path` arrives as `/uploads/<secret>/<filename>` — already the
    # API's own suffix — so it is appended verbatim. The project path must be
    # fully escaped: nested namespaces (modulosource/powerpanne/powerpanne/core)
    # would otherwise read as path segments and 404.
    def upload_api_url(gitlab_url, project_path, upload_path)
      "#{gitlab_url.to_s.chomp('/')}/api/v4/projects/#{CGI.escape(project_path.to_s)}#{upload_path}"
    end

    # Leading bytes → MIME type, for the formats AutospecAttachment accepts.
    # WebP needs two probes (RIFF container + WEBP fourcc) so it is handled
    # separately in `sniff_image_type`.
    IMAGE_SIGNATURES = {
      "\x89PNG\r\n\x1A\n".b => 'image/png',
      "\xFF\xD8\xFF".b => 'image/jpeg',
      'GIF87a'.b => 'image/gif',
      'GIF89a'.b => 'image/gif'
    }.freeze

    # Returns the MIME type when the body really is an image, else nil.
    #
    # Sniffing rather than trusting `Content-Type`, for two reasons that bit us
    # at once: the API endpoint answers `application/octet-stream`, so a
    # `start_with?('image/')` check rejected valid bytes; and the sign-in page
    # answers a perfectly well-formed `text/html` 200, so a permissive check
    # would have attached an HTML page to a draft as a "screenshot".
    def sniff_image_type(body)
      return nil if body.nil? || body.empty?

      bytes = body.b
      IMAGE_SIGNATURES.each { |signature, type| return type if bytes.start_with?(signature) }
      return 'image/webp' if bytes[0, 4] == 'RIFF'.b && bytes[8, 4] == 'WEBP'.b

      nil
    end

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
      url = upload_api_url(opts[:gitlab_url], opts[:project_path], upload_path)
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
      # Sniffed, not read off the header: the API endpoint answers
      # `application/octet-stream` for a perfectly valid PNG. See
      # `sniff_image_type`.
      unless sniff_image_type(body)
        return "[Image: #{filename} -- format non support\u00E9 (#{response['content-type']})]"
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
    #
    # The rescue that used to make this "non-fatal" went with Autodev #67. A
    # ticket's comments are not decoration: bug #32 is the case where the whole
    # instruction ("la recette est KO, il manque X") lives in a comment posted
    # after the first delivery, and a prompt silently missing them reads as a
    # ticket nobody commented on. Same endpoint, same rule as `human_comment_since?`.
    def append_comments(lines, client, project_path, issue_iid, img_opts)
      notes = GitlabHelpers.answer(:issue_notes) do
        client.issue_notes(project_path, issue_iid, per_page: 100).auto_paginate
      end
      user_notes = notes.reject { |n| n.system || n.body.to_s.include?('**autodev**') }
      return unless user_notes.any?

      lines << '## Comments'
      lines << ''
      user_notes.each { |note| append_single_comment(lines, note, img_opts) }
    end

    # Format and append a single comment note.
    def append_single_comment(lines, note, img_opts)
      lines << "### #{note.author&.name || 'Unknown'} (#{note.created_at})"
      lines << ImageDownloader.maybe_download(note.body.to_s, img_opts)
      lines << ''
    end

    # Append related issue links to the lines array.
    #
    # The one swallow left in `fetch_full_context`'s subtree, and deliberately
    # (Autodev #67): this rescue exists for a *capability* gap, not an outage —
    # the endpoint is absent on older GitLab, which is what the `NoMethodError`
    # clause is about, and there is no way to ask "do you support this" other
    # than calling it. The substitute removes a list of sibling ticket titles
    # from a prompt; it answers no question and decides nothing.
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
      GitlabHelpers.field(pos, field)
    end
  end
end
