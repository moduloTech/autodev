# frozen_string_literal: true

# A capture (drag-drop image, screenshot, mockup) attached to an
# AutospecDraft. See autodev/docs/autospec.md §F for the two-stage
# lifecycle: ActiveStorage on local disk while the draft is being edited
# / approved, then uploaded to GitLab at submission time (and the draft
# markdown rewritten to point at the GitLab URL).
#
# The has_one_attached anchor is the file itself; everything we know
# about it (filename, content_type, byte_size, width/height post-analyze)
# lives on the ActiveStorage::Blob record, not on this row.
class AutospecAttachment < ApplicationRecord
  belongs_to :autospec_draft

  has_one_attached :file
end
