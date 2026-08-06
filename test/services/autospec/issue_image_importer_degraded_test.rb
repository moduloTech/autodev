# frozen_string_literal: true

require_relative '../../rails_helper'
require_relative 'image_importer_support'

module Autospec
  # IssueImageImporter's degraded paths (Autodev #37): an image that can't be
  # fetched costs that one image and nothing else — the import is never
  # aborted, since throwing away a long issue body over one unreachable PNG
  # helps nobody. Happy path lives in issue_image_importer_test.rb.
  class IssueImageImporterDegradedTest < ActiveSupport::TestCase
    include ImageImporterSupport

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

    # This is what actually happened in prod before the endpoint fix: GitLab
    # answered 200 with its sign-in page. Refusing on content — not on the
    # header — is what stopped an HTML page being attached as a "screenshot",
    # and it must keep doing so now that the header is no longer trusted.
    def test_the_sign_in_html_page_is_refused
      html = ok(body: '<!DOCTYPE html><html><body>Sign in</body></html>', content_type: 'text/html')
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
  end
end
