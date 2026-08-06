# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Downloading a GitLab upload with an API token (Autodev #37 follow-up).
#
# Measured against source.modulotech.fr on 2026-08-06: the project-relative
# `<host>/<project>/uploads/<secret>/<file>.png` path answers **200
# text/html** to a PRIVATE-TOKEN request — GitLab serves the sign-in page,
# because that route is session-cookie only. The token-authenticated
# equivalent is `GET /api/v4/projects/:url_encoded_path/uploads/:secret/:file`,
# which answered 200 with the real 935 KB image.
#
# Two consequences, both fixed here:
#   1. the URL must target the API endpoint, not the web path;
#   2. that endpoint answers `application/octet-stream`, so a
#      `content_type.start_with?('image/')` check would reject the very bytes
#      it was meant to accept. Validation is by magic bytes instead, which
#      also keeps rejecting the HTML sign-in page.
class GitlabUploadDownloadTest < Minitest::Test
  PNG  = "\x89PNG\r\n\x1A\n".b + ('x' * 8).b
  JPEG = "\xFF\xD8\xFF".b + ('x' * 8).b
  GIF  = 'GIF89a'.b + ('x' * 8).b
  WEBP = "RIFF\x00\x00\x00\x00WEBP".b
  HTML = '<!DOCTYPE html><html><body>Sign in</body></html>'.b

  # --- URL construction ---------------------------------------------

  def url_for(project_path)
    GitlabHelpers::ImageDownloader.upload_api_url(
      'https://gitlab.example.com', project_path, '/uploads/abc123/shot.png'
    )
  end

  def test_targets_the_token_authenticated_api_endpoint
    assert_equal 'https://gitlab.example.com/api/v4/projects/group%2Fproj/uploads/abc123/shot.png',
                 url_for('group/proj')
  end

  # A nested namespace is the common case at Modulotech
  # (modulosource/powerpanne/powerpanne/core) and every slash must be encoded
  # or the API reads it as a path segment and 404s.
  def test_encodes_every_slash_of_a_nested_namespace
    assert_includes url_for('a/b/c/d'), '/projects/a%2Fb%2Fc%2Fd/uploads/'
  end

  def test_tolerates_a_trailing_slash_on_the_host
    url = GitlabHelpers::ImageDownloader.upload_api_url(
      'https://gitlab.example.com/', 'group/proj', '/uploads/abc/shot.png'
    )

    assert_includes url, 'com/api/v4/'
    refute_includes url, 'com//api'
  end

  # --- content sniffing ----------------------------------------------

  def sniff(bytes) = GitlabHelpers::ImageDownloader.sniff_image_type(bytes)

  def test_recognises_png
    assert_equal 'image/png', sniff(PNG)
  end

  def test_recognises_jpeg
    assert_equal 'image/jpeg', sniff(JPEG)
  end

  def test_recognises_gif
    assert_equal 'image/gif', sniff(GIF)
  end

  def test_recognises_webp
    assert_equal 'image/webp', sniff(WEBP)
  end

  # The exact failure observed in prod: a 200 whose body is the sign-in page.
  # Sniffing must keep refusing it — that guard is what stopped an HTML page
  # being attached to a draft as a "screenshot".
  def test_refuses_the_sign_in_html_page
    assert_nil sniff(HTML)
  end

  def test_refuses_empty_and_nil_bodies
    assert_nil sniff('')
    assert_nil sniff(nil)
  end

  # A body shorter than the signature must not raise.
  def test_refuses_a_truncated_body
    assert_nil sniff("\x89PN".b)
  end
end
