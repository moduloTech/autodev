# frozen_string_literal: true

module Autospec
  # Rapatriates the images embedded in an imported GitLab issue body into
  # local `AutospecAttachment` rows (Autodev #37).
  #
  # This is the exact inverse of `GitlabSubmitter`: submission uploads each
  # local blob to GitLab's `/uploads` endpoint and rewrites the markdown to
  # the returned snippet, so import downloads each `/uploads/...` reference
  # and rewrites it to `rails_blob_path` — the very string the submitter
  # matches on when the draft eventually ships. That symmetry is what makes an
  # imported draft indistinguishable from one where the CSM dropped the images
  # by hand (see autospec.md §F's two-stage lifecycle).
  #
  # Import is deliberately **degraded, never aborted**: an image that can't be
  # fetched keeps its original GitLab reference and adds a line to `warnings`,
  # which the controller surfaces as a flash. Matches how the rest of the
  # codebase treats GitLab failures — degrade, don't take the page down — and
  # avoids throwing away a long issue body over one unreachable PNG.
  #
  # Only `![alt](/uploads/…)` references are considered. Non-image uploads are
  # linked as `[name](/uploads/…)` (no leading `!`); `AutospecAttachment` is an
  # image surface, so those are left untouched rather than half-imported.
  class IssueImageImporter
    # Mirrors GitlabHelpers.download_gitlab_images' pattern, including the
    # optional `{width=… height=…}` suffix GitLab appends when an image is
    # resized in its editor — matched so it's consumed by the rewrite instead
    # of being left behind as stray text next to the new link.
    IMAGE_REF_RE = %r{!\[([^\]]*)\]\((/uploads/[^)]+)\)(\{[^\}]*\})?}

    Result = Struct.new(:markdown, :warnings)

    # Normalized shape of a fetch, so the HTTP layer can be swapped in tests
    # without fabricating Net::HTTP responses.
    Fetched = Struct.new(:ok, :body, :content_type)

    # Reuses the redirect-following, PRIVATE-TOKEN-authenticated GET that
    # already serves the danger-claude context path — same auth, same 3-hop
    # redirect budget, one implementation.
    DEFAULT_FETCHER = lambda do |url, token|
      response = GitlabHelpers::ImageDownloader.http_get_with_redirects(url, token)
      Fetched.new(ok: response.is_a?(Net::HTTPSuccess), body: response.body,
                  content_type: response['content-type'].to_s)
    end

    def initialize(draft, gitlab_url:, token:, fetcher: nil)
      @draft = draft
      @gitlab_url = gitlab_url.to_s.chomp('/')
      @token = token
      @fetcher = fetcher || DEFAULT_FETCHER
      @warnings = []
    end

    def call(markdown)
      rewritten = markdown.to_s.gsub(IMAGE_REF_RE) do
        import_one(::Regexp.last_match(1), ::Regexp.last_match(2), ::Regexp.last_match(0))
      end
      Result.new(markdown: rewritten, warnings: @warnings)
    end

    private

    # Returns the replacement text for one matched reference: the local blob
    # link on success, the untouched original on any failure.
    def import_one(alt, upload_path, original)
      filename = File.basename(upload_path)
      return warn_and_keep(filename, original, :no_credentials) unless credentials?

      fetched = @fetcher.call(download_url(upload_path), @token)
      return warn_and_keep(filename, original, :unreachable) unless fetched.ok

      content_type = image_type(fetched)
      return warn_and_keep(filename, original, :not_an_image) unless content_type

      "![#{alt}](#{attach!(fetched, filename, content_type)})"
    rescue StandardError => e
      # Anything unexpected (network reset, ActiveStorage failure, a malformed
      # blob) costs one image, not the import.
      warn_and_keep(filename, original, "#{e.class}: #{e.message}")
    end

    def credentials?
      @gitlab_url.present? && @token.present?
    end

    # The API endpoint, not the project-relative `/uploads/…` path the body
    # references: that one is session-cookie only and answers a PRIVATE-TOKEN
    # request with 200 + the sign-in page. See
    # GitlabHelpers::ImageDownloader.upload_api_url.
    def download_url(upload_path)
      GitlabHelpers::ImageDownloader.upload_api_url(@gitlab_url, @draft.project.gitlab_path, upload_path)
    end

    # Sniffed from the bytes rather than read off the header — the API answers
    # `application/octet-stream` for a valid PNG, while the sign-in page
    # answers a well-formed `text/html`. Returns the real MIME type or nil.
    def image_type(fetched)
      GitlabHelpers::ImageDownloader.sniff_image_type(fetched.body)
    end

    # Returns the local blob path the rewritten markdown points at.
    def attach!(fetched, filename, content_type)
      attachment = @draft.autospec_attachments.create!
      attachment.file.attach(
        io: StringIO.new(fetched.body.b), filename: filename, content_type: content_type
      )
      Rails.application.routes.url_helpers.rails_blob_path(attachment.file, only_path: true)
    end

    def warn_and_keep(filename, original, reason)
      @warnings << "#{filename} (#{reason})"
      original
    end
  end
end
