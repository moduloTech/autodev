# frozen_string_literal: true

require 'tempfile'
require 'gitlab'

module Autospec
  # Creates a real GitLab issue from an approved AutoSpec draft. Called
  # at finalize time from `ApprovalRecorder` once quorum is reached.
  # See autodev/docs/autospec.md §F "Flux à deux temps" — attachments
  # live in ActiveStorage during drafting/approval, then move to
  # GitLab's `/projects/:id/uploads` at submission time and the
  # markdown is rewritten to point at GitLab URLs.
  #
  # Synchronous + transactional with the AASM finalize transition:
  # ApprovalRecorder calls `#submit!` inside its DB transaction, so
  # a GitLab API failure rolls back the local state (approval row +
  # AASM transition + draft stamps) and the operator can retry by
  # clicking Approuver again. The GitLab side may carry orphan
  # uploads if the failure happens after upload_file but before
  # create_issue — acceptable for the MVP; step 12+ could move this
  # to a job + reconcile loop.
  #
  # Test seam: pass `client:` and `config:` to the constructor.
  # Production builds them from `Web.config` lazily.
  class GitlabSubmitter
    class SubmissionFailed < StandardError; end

    class << self
      # Test seam: when set to true, `#submit!` is a no-op (returns nil
      # without touching GitLab). Tests for the broader workflow
      # (ApprovalRecorder, controllers) flip this in setup/teardown so
      # they don't need to stub the gitlab gem. The GitlabSubmitter's
      # own tests leave it alone and inject `client:` instead.
      attr_accessor :disabled
    end

    def initialize(draft, client: nil, config: nil)
      @draft  = draft
      @client = client
      @config = config
    end

    def submit! # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      return if self.class.disabled

      raise SubmissionFailed, "draft ##{@draft.id} already submitted" if @draft.submitted_at.present?

      uploads = upload_attachments
      markdown = rewrite_markdown(@draft.markdown.to_s, uploads)
      issue = create_issue(markdown)

      @draft.update!(
        gitlab_issue_iid: extract(issue, :iid),
        gitlab_issue_url: extract(issue, :web_url),
        submitted_at: Time.current
      )
    rescue Gitlab::Error::Error => e
      raise SubmissionFailed, "GitLab API error: #{e.class}: #{e.message}"
    end

    private

    def project_path
      @draft.project.gitlab_path
    end

    def client
      @client ||= build_client
    end

    def build_client
      cfg = config_hash
      GitlabHelpers.build_gitlab_client(cfg['gitlab_url'], cfg['gitlab_token'])
    end

    def config_hash
      @config || (defined?(::Web) && ::Web.respond_to?(:config) && ::Web.config) || {}
    end

    # Upload every attached blob via GitLab's /uploads endpoint. Each
    # blob is streamed to a Tempfile (the gitlab gem's `upload_file`
    # API takes a file path, not raw bytes or an IO). Returns a list of
    # `{ local_url, gitlab_snippet }` pairs for the markdown rewriter.
    def upload_attachments
      @draft.autospec_attachments.with_attached_file.map do |attachment|
        local_url = Rails.application.routes.url_helpers.rails_blob_path(attachment.file, only_path: true)
        gitlab_snippet = upload_blob_to_gitlab(attachment.file)
        { local_url: local_url, gitlab_snippet: gitlab_snippet }
      end
    end

    def upload_blob_to_gitlab(file_attachment) # rubocop:disable Metrics/AbcSize
      blob = file_attachment.blob
      ext = File.extname(blob.filename.to_s)
      Tempfile.create([blob.filename.base, ext.presence || '.bin']) do |tmp|
        tmp.binmode
        tmp.write(blob.download)
        tmp.flush
        response = client.upload_file(project_path, tmp.path)
        # GitLab's gem exposes `.markdown` (the full snippet, e.g.
        # `![filename](/uploads/abc/file.png)`) and `.url` (the path).
        # We use the URL path so we can reuse the *alt text* from the
        # CSM's original snippet on rewrite.
        return extract(response, :url)
      end
    end

    # Swap any markdown link whose URL matches a local blob path with
    # the corresponding GitLab upload URL. Naive substring replace —
    # works because rails_blob_path embeds a signed_id which is unique
    # per blob and unlikely to collide with anything else in the body.
    def rewrite_markdown(text, uploads)
      uploads.reduce(text) do |acc, upload|
        acc.gsub(upload[:local_url], upload[:gitlab_snippet])
      end
    end

    def create_issue(markdown)
      client.create_issue(project_path, issue_title,
                          description: markdown,
                          labels: labels_for_destination.join(','))
    end

    def issue_title
      @draft.title.presence || '(sans titre)'
    end

    # Apply the project's `labels_todo` only when the draft was sent
    # to AutoDev — that's the signal the poller uses to pick the
    # issue up. Human-destination drafts ship label-less; whoever
    # opens the issue assigns the appropriate `Doing` label by hand.
    def labels_for_destination
      return [] unless @draft.destination == AutospecDraft::DESTINATION_AUTODEV

      project_cfg = Array(config_hash['projects']).find { |p| p['path'] == project_path } || {}
      Array(project_cfg['labels_todo'])
    end

    # The gitlab gem returns BaseModel objects with attribute readers;
    # tests pass plain Structs / OpenStructs. Delegates to the canonical accessor.
    def extract(obj, key)
      GitlabHelpers.field(obj, key)
    end
  end
end
