# frozen_string_literal: true

module Autospec
  # Shared fixtures for the IssueImageImporter tests, split across a
  # happy-path file and a degraded-import file (Autodev #37).
  #
  # The fetcher is injected rather than stubbed at the HTTP layer: the service
  # takes a `fetcher:` seam precisely so these tests never touch the network.
  module ImageImporterSupport
    PNG = "\x89PNG\r\n\x1A\n".b

    def self.included(base)
      base.setup do
        @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
        @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
        @draft   = AutospecDraft.create!(user: @user, project: @project, title: 'T', markdown: '')
        @calls   = []
      end
    end

    def ok(body: PNG, content_type: 'image/png')
      IssueImageImporter::Fetched.new(ok: true, body: body, content_type: content_type)
    end

    def failed
      IssueImageImporter::Fetched.new(ok: false, body: '', content_type: '')
    end

    # Answers each queued response in turn, the last one repeating, so a
    # multi-image body can mix success and failure.
    def fetcher(*queued)
      lambda do |url, token|
        @calls << { url: url, token: token }
        queued.size > 1 ? queued.shift : queued.first
      end
    end

    def import(markdown, fetch = nil, token: 'tok')
      IssueImageImporter.new(@draft, gitlab_url: 'https://gitlab.example.com',
                                     token: token, fetcher: fetch || fetcher(ok)).call(markdown)
    end

    def attachments
      @draft.autospec_attachments
    end

    def blob_path(attachment)
      Rails.application.routes.url_helpers.rails_blob_path(attachment.file, only_path: true)
    end
  end
end
