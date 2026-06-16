# frozen_string_literal: true

# HTTP surface for AutoSpec draft attachments — drag-drop captures (PNG /
# JPG / GIF / WEBP) the CSM drops on the editor column. Step 10c of
# phase D (autodev/docs/autospec.md §F "Flux à deux temps") wires the
# upload + delete endpoints; step 11's GitlabSubmitter will download
# each blob at submission time, push to GitLab's `/projects/:id/uploads`,
# and rewrite the markdown to point at GitLab URLs.
#
# Author-only at the MVP (mirrors AutospecDraftsController). The wider
# owner/contributor matrix (§J) is wired with the approval workflow.
class AutospecAttachmentsController < ApplicationController
  include ::Web::Helpers

  MAX_BYTES    = 10.megabytes
  # We don't ship ImageMagick / libvips, so ActiveStorage's analyzer won't
  # populate width/height — the allowlist is purely a guard against the
  # CSM dropping a .pdf or .exe by accident. Tightening to a precise list
  # also lets the GitlabSubmitter (step 11) assume safe content types.
  ALLOWED_MIME = %r{\Aimage/(png|jpe?g|gif|webp)\z}

  before_action :load_draft
  before_action :authorize_author!

  # POST /autospec_drafts/:autospec_draft_id/autospec_attachments
  def create
    file = params[:file]
    error_key, error_status = validate_upload(file)
    return render_error(error_key, error_status) if error_key

    attachment = @draft.autospec_attachments.create!
    attachment.file.attach(io: file.to_io, filename: file.original_filename,
                           content_type: file.content_type)

    render json: { attachment: serialise(attachment) }, status: :created
  end

  # DELETE /autospec_drafts/:autospec_draft_id/autospec_attachments/:id
  def destroy
    attachment = @draft.autospec_attachments.find(params[:id])
    attachment.destroy!
    head :no_content
  end

  private

  def load_draft
    @draft = AutospecDraft.find(params[:autospec_draft_id])
  end

  def authorize_author!
    return if @draft.user_id == current_user.id

    render json: { error: 'forbidden' }, status: :forbidden
  end

  def uploaded_file?(value)
    value.respond_to?(:original_filename) && value.respond_to?(:content_type)
  end

  def allowed_mime?(file)
    ALLOWED_MIME.match?(file.content_type.to_s)
  end

  # Returns [error_key, status] when the upload is invalid; nil otherwise.
  def validate_upload(file)
    return ['attachment_missing', :bad_request]            unless uploaded_file?(file)
    return ['attachment_too_large', :content_too_large]    if file.size > MAX_BYTES
    return ['attachment_bad_type', :unsupported_media_type] unless allowed_mime?(file)

    nil
  end

  def render_error(key, status)
    render json: { error: key }, status: status
  end

  def serialise(attachment)
    blob = attachment.file.blob
    url  = Rails.application.routes.url_helpers.rails_blob_path(attachment.file, only_path: true)
    serialised_blob(blob).merge(id: attachment.id, url: url,
                                markdown_snippet: "![#{blob.filename}](#{url})")
  end

  def serialised_blob(blob)
    {
      filename: blob.filename.to_s,
      content_type: blob.content_type,
      byte_size: blob.byte_size,
      width: blob.metadata['width'],
      height: blob.metadata['height']
    }
  end
end
