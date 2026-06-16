# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'
require 'rack/test'

# HTTP-contract tests for AutospecAttachmentsController (phase D step
# 10c — drag-drop captures). The drag-drop JS is exercised through the
# Show view; this file covers the upload + delete endpoint shape and
# its guards (auth, type, size).
class AutospecAttachmentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @other   = User.create!(email: 'other@modulotech.fr', name: 'Other')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
    @draft   = AutospecDraft.create!(user: @author, project: @project, title: 'X')
  end

  # 1×1 transparent PNG so the IO has plausible image bytes. The
  # controller does NOT introspect the file content — only `content_type`
  # — so the exact bytes don't matter for the contract tests.
  PNG_1X1 = "\x89PNG\r\n\x1a\n" \
            "\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" \
            "\x00\x00\x00\rIDATx\x9cc\xfc\xff\xff?\x03\x00\x05\x00\x02\x00\x01\xd5\xc6\x99\x91" \
            "\x00\x00\x00\x00IEND\xaeB`\x82".b
  private_constant :PNG_1X1

  def upload(bytes:, filename:, content_type:)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), content_type, original_filename: filename)
  end

  def png(bytes: PNG_1X1, filename: 'cap.png')
    upload(bytes: bytes, filename: filename, content_type: 'image/png')
  end

  # --- create -----------------------------------------------------

  def test_create_requires_signed_in_user
    # `as: :multipart` sets the request Content-Type but not Accept;
    # Devise's failure_app falls back to an HTML redirect to /sign_in
    # unless we tell it the client wants JSON. The drag-drop JS does
    # set Accept: application/json on its fetch() call, so this mirrors
    # the actual runtime behaviour.
    post "/autospec_drafts/#{@draft.id}/autospec_attachments",
         params: { file: png }, as: :multipart, headers: { 'Accept' => 'application/json' }

    assert_response :unauthorized
  end

  def test_create_forbids_non_author
    sign_in @other
    post "/autospec_drafts/#{@draft.id}/autospec_attachments", params: { file: png }, as: :multipart

    assert_response :forbidden
  end

  def test_create_persists_attachment
    sign_in @author

    assert_difference '@draft.autospec_attachments.count', 1 do
      post "/autospec_drafts/#{@draft.id}/autospec_attachments",
           params: { file: png }, as: :multipart
    end
    assert_response :created
  end

  def test_create_returns_serialised_attachment
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/autospec_attachments",
         params: { file: png(filename: 'screenshot.png') }, as: :multipart
    body = JSON.parse(response.body)['attachment']

    assert_equal 'screenshot.png', body['filename']
    assert_match(%r{/rails/active_storage/blobs/}, body['url'])
    assert_match(%r{\A!\[screenshot\.png\]\(/rails/active_storage/blobs/}, body['markdown_snippet'])
  end

  def test_create_rejects_missing_file
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/autospec_attachments", as: :multipart

    assert_response :bad_request
    assert_equal 'attachment_missing', JSON.parse(response.body)['error']
  end

  def test_create_rejects_non_image_content_type
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/autospec_attachments",
         params: { file: upload(bytes: 'pdf', filename: 'doc.pdf',
                                content_type: 'application/pdf') },
         as: :multipart

    assert_response :unsupported_media_type
    assert_equal 'attachment_bad_type', JSON.parse(response.body)['error']
  end

  def test_create_rejects_oversized_file
    sign_in @author
    too_big = 'a' * (10.megabytes + 1)
    post "/autospec_drafts/#{@draft.id}/autospec_attachments",
         params: { file: upload(bytes: too_big, filename: 'huge.png',
                                content_type: 'image/png') },
         as: :multipart

    assert_response :content_too_large
    assert_equal 'attachment_too_large', JSON.parse(response.body)['error']
  end

  # --- destroy ----------------------------------------------------

  def test_destroy_removes_attachment
    sign_in @author
    attachment = @draft.autospec_attachments.create!
    attachment.file.attach(io: StringIO.new(PNG_1X1), filename: 'x.png', content_type: 'image/png')

    assert_difference '@draft.autospec_attachments.count', -1 do
      delete "/autospec_drafts/#{@draft.id}/autospec_attachments/#{attachment.id}"
    end
    assert_response :no_content
  end

  def test_destroy_forbids_non_author
    sign_in @other
    attachment = @draft.autospec_attachments.create!
    delete "/autospec_drafts/#{@draft.id}/autospec_attachments/#{attachment.id}"

    assert_response :forbidden
  end
end
