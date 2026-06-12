# frozen_string_literal: true

require_relative '../rails_helper'

class AutospecAttachmentTest < ActiveSupport::TestCase
  setup do
    @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
    @draft   = AutospecDraft.create!(user: @user, project: @project)
  end

  def test_draft_required
    refute_predicate AutospecAttachment.new, :valid?
  end

  def attach_fixture(attachment)
    attachment.file.attach(io: StringIO.new('PNG-BYTES'),
                           filename: 'capture.png', content_type: 'image/png')
  end

  def test_file_attachment_marks_attached
    attachment = AutospecAttachment.create!(autospec_draft: @draft)
    attach_fixture(attachment)

    assert_predicate attachment.file, :attached?
  end

  def test_file_attachment_persists_metadata
    attachment = AutospecAttachment.create!(autospec_draft: @draft)
    attach_fixture(attachment)

    assert_equal 'capture.png', attachment.file.filename.to_s
    assert_equal 'image/png',   attachment.file.content_type
  end

  def test_file_attachment_round_trips_content
    attachment = AutospecAttachment.create!(autospec_draft: @draft)
    attach_fixture(attachment)

    assert_equal 'PNG-BYTES', attachment.file.download
  end

  def test_belongs_to_draft
    attachment = AutospecAttachment.create!(autospec_draft: @draft)

    assert_equal @draft, attachment.autospec_draft
  end
end
