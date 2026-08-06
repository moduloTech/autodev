# frozen_string_literal: true

require_relative '../../rails_helper'
require_relative 'image_importer_support'

module Autospec
  # Rapatriating an imported GitLab issue's inline images into local
  # AutospecAttachment rows (Autodev #37) — the inverse of GitlabSubmitter.
  # Degraded-import behaviour lives in issue_image_importer_degraded_test.rb.
  class IssueImageImporterTest < ActiveSupport::TestCase
    include ImageImporterSupport

    # --- download mechanics -------------------------------------------

    # The API endpoint, not the project-relative web path: the latter is
    # session-cookie only and answers a PRIVATE-TOKEN request with 200 + the
    # sign-in page, which is how #37 shipped broken.
    def test_downloads_through_the_token_authenticated_api_endpoint
      import('![c](/uploads/abc123/shot.png)')

      assert_equal 'https://gitlab.example.com/api/v4/projects/group%2Fproj/uploads/abc123/shot.png',
                   @calls.first[:url]
      assert_equal 'tok', @calls.first[:token]
    end

    # The exact prod condition: that endpoint labels a valid PNG
    # `application/octet-stream`. Trusting the header rejected the very bytes
    # the fix went to fetch, so the type is sniffed and the attachment stores
    # the real one.
    def test_accepts_an_octet_stream_body_and_stores_the_sniffed_type
      import('![c](/uploads/abc/shot.png)', fetcher(ok(content_type: 'application/octet-stream')))

      assert_equal 1, attachments.count
      assert_equal 'image/png', attachments.first.file.content_type
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

    # --- round-trip with the submitter -------------------------------

    # The point of rewriting to `rails_blob_path`: GitlabSubmitter matches on
    # exactly that string when it swaps local blobs back to GitLab uploads at
    # submission time. If the two drift, an imported image ships as a dead link.
    def test_rewritten_path_is_what_the_submitter_looks_for
      result = import('![c](/uploads/abc/shot.png)')

      assert_includes result.markdown, blob_path(attachments.first)
    end
  end
end
