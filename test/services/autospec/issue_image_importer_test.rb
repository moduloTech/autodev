# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  # Rapatriating an imported GitLab issue's inline images into local
  # AutospecAttachment rows (Autodev #37) — the inverse of GitlabSubmitter.
  class IssueImageImporterTest < ActiveSupport::TestCase
    PNG = "\x89PNG\r\n\x1A\n".b

    setup do
      @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
      @draft   = AutospecDraft.create!(user: @user, project: @project, title: 'T', markdown: '')
      @calls   = []
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

    # --- happy path -------------------------------------------------

    def test_downloads_the_image_and_attaches_it_to_the_draft
      import('Voir ![capture](/uploads/abc123/shot.png) ci-dessus')

      assert_equal 1, attachments.count
      assert_equal 'shot.png', attachments.first.file.filename.to_s
      assert_equal 'image/png', attachments.first.file.content_type
    end

    def test_rewrites_the_reference_to_the_local_blob_path
      result = import('![capture](/uploads/abc123/shot.png)')

      assert_equal "![capture](#{blob_path(attachments.first)})", result.markdown
    end

    def test_builds_the_download_url_from_the_project_path
      import('![c](/uploads/abc123/shot.png)')

      assert_equal 'https://gitlab.example.com/group/proj/uploads/abc123/shot.png', @calls.first[:url]
      assert_equal 'tok', @calls.first[:token]
    end

    def test_imports_every_image_in_the_body
      import("![a](/uploads/h1/a.png)\n\n![b](/uploads/h2/b.png)")

      assert_equal %w[a.png b.png], attachments.map { |a| a.file.filename.to_s }.sort
    end

    # The `{width=…}` suffix GitLab appends on a resized image is part of the
    # matched reference — it must not survive as stray text after the rewrite.
    def test_strips_a_gitlab_size_suffix
      result = import('![c](/uploads/abc/shot.png){width=300 height=200}')

      assert_not_includes result.markdown, 'width=300'
    end

    # --- degraded import: never aborts ------------------------------

    def test_an_unreachable_image_keeps_its_original_reference
      result = import('![c](/uploads/abc/shot.png)', fetcher(failed))

      assert_equal '![c](/uploads/abc/shot.png)', result.markdown
      assert_equal 0, attachments.count
    end

    def test_a_failed_download_is_reported_with_its_filename
      result = import('![c](/uploads/abc/shot.png)', fetcher(failed))

      assert_equal 1, result.warnings.size
      assert_includes result.warnings.first, 'shot.png'
    end

    # A GitLab login page answers 200 text/html. Refusing on content type is
    # what stops it being attached as a "screenshot".
    def test_a_non_image_response_is_refused
      html = ok(body: '<html>login</html>', content_type: 'text/html')
      result = import('![c](/uploads/abc/shot.png)', fetcher(html))

      assert_equal 0, attachments.count
      assert_equal 1, result.warnings.size
    end

    def test_a_failing_image_does_not_block_the_others
      result = import("![a](/uploads/h1/a.png)\n![b](/uploads/h2/b.png)", fetcher(failed, ok))

      assert_equal 'b.png', attachments.sole.file.filename.to_s
      assert_includes result.markdown, '![a](/uploads/h1/a.png)'
    end

    def test_an_unexpected_error_degrades_instead_of_raising
      result = import('![c](/uploads/abc/shot.png)', ->(*) { raise IOError, 'connection reset' })

      assert_equal '![c](/uploads/abc/shot.png)', result.markdown
      assert_equal 1, result.warnings.size
    end

    def test_a_missing_token_warns_without_downloading
      result = import('![c](/uploads/abc/shot.png)', token: nil)

      assert_empty @calls
      assert_equal 1, result.warnings.size
    end

    # --- no-op ------------------------------------------------------

    def test_leaves_a_body_without_uploads_untouched
      result = import('Juste ![un lien](https://example.com/x.png)')

      assert_empty @calls
      assert_equal 'Juste ![un lien](https://example.com/x.png)', result.markdown
    end

    # Non-image uploads are linked as `[name](/uploads/…)`, without the
    # leading `!`. AutospecAttachment is an image surface, so they are left
    # alone rather than half-imported.
    def test_leaves_non_image_upload_links_untouched
      result = import('Trace: [debug.log](/uploads/abc/debug.log)')

      assert_empty @calls
      assert_equal 'Trace: [debug.log](/uploads/abc/debug.log)', result.markdown
    end

    # The point of rewriting to `rails_blob_path`: GitlabSubmitter matches on
    # exactly that string when it swaps local blobs back to GitLab uploads at
    # submission time. If the two drift, an imported image ships as a dead link.
    def test_rewritten_path_is_what_the_submitter_looks_for
      result = import('![c](/uploads/abc/shot.png)')

      assert_includes result.markdown, blob_path(attachments.first)
    end
  end
end
