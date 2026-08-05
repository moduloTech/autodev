# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  # GitlabImporter's inline-image rapatriation (Autodev #37): the wiring
  # between the importer and IssueImageImporter. The service's own behaviour
  # (download URL shape, degraded paths, round-trip with the submitter) is
  # covered by issue_image_importer_test.rb — this only asserts the importer
  # runs it, persists the rewritten body, and exposes the warnings.
  class GitlabImporterImagesTest < ActiveSupport::TestCase
    StubClient = Struct.new(:response) do
      def issue(_project_path, _iid)
        response
      end
    end

    IssueResponse = Struct.new(:title, :description)

    PNG = "\x89PNG\r\n\x1A\n".b
    CONFIG = { 'gitlab_url' => 'https://gitlab.example.com', 'gitlab_token' => 'tok' }.freeze
    ISSUE_URL = 'https://gitlab.example.com/group/proj/-/issues/42'
    BODY = 'Repro : ![capture](/uploads/abc/shot.png)'

    setup do
      @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
      ProjectMembership.create!(user: @user, project: @project, role: 'contributor')
    end

    def importer(body, success: true)
      fetched = IssueImageImporter::Fetched.new(ok: success, body: PNG, content_type: 'image/png')
      GitlabImporter.new(ISSUE_URL, @user,
                         client: StubClient.new(IssueResponse.new('Login bug', body)),
                         config: CONFIG, image_fetcher: ->(_url, _token) { fetched })
    end

    def test_imports_the_issue_images_as_draft_attachments
      draft = importer(BODY).call

      assert_equal 1, draft.autospec_attachments.count
      assert_not_includes draft.markdown, '/uploads/abc/shot.png'
    end

    def test_a_clean_import_reports_no_warning
      subject = importer(BODY)
      subject.call

      assert_empty subject.warnings
    end

    # User decision on #37: a failed download degrades the import, it never
    # aborts it — the body and every reachable image still land.
    def test_a_failed_image_download_still_produces_the_draft
      draft = importer(BODY, success: false).call

      assert_equal 'Login bug', draft.title
      assert_equal 0, draft.autospec_attachments.count
    end

    def test_a_failed_image_keeps_its_original_link_and_warns
      subject = importer(BODY, success: false)
      draft = subject.call

      assert_includes draft.markdown, '/uploads/abc/shot.png'
      assert_equal 1, subject.warnings.size
    end

    def test_warnings_are_empty_when_the_issue_has_no_image
      subject = importer('Just text')
      subject.call

      assert_empty subject.warnings
    end
  end
end
