# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class GitlabImporterTest < ActiveSupport::TestCase
    # Stub for Gitlab::Client. `issue` returns the queued response or
    # raises whatever sits in the `error` slot.
    StubClient = Struct.new(:response, :calls, :error) do
      def issue(project_path, iid)
        calls << { project: project_path, iid: iid }
        raise error if error

        response
      end
    end

    IssueResponse = Struct.new(:title, :description)

    setup do
      @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
      ProjectMembership.create!(user: @user, project: @project, role: 'contributor')
    end

    def stub_client(issue: IssueResponse.new('Login bug', 'Steps to reproduce'), error: nil)
      StubClient.new(issue, [], error)
    end

    # --- happy path -------------------------------------------------

    def test_creates_draft_with_issue_title_and_description
      importer = GitlabImporter.new('https://gitlab.example.com/group/proj/-/issues/42',
                                    @user, client: stub_client)
      draft = importer.call

      assert_equal ['Login bug', 'Steps to reproduce'], [draft.title, draft.markdown]
      assert_equal [@user, @project], [draft.user, draft.project]
    end

    def test_supports_nested_namespace_paths
      nested = Project.create!(gitlab_path: 'group/sub/proj', slug: 'group__sub__proj')
      ProjectMembership.create!(user: @user, project: nested, role: 'contributor')
      client = stub_client
      GitlabImporter.new('https://gitlab.example.com/group/sub/proj/-/issues/7',
                         @user, client: client).call

      assert_equal 'group/sub/proj', client.calls.first[:project]
      assert_equal 7, client.calls.first[:iid]
    end

    def test_handles_trailing_slash_and_query_string
      client = stub_client
      GitlabImporter.new('https://gitlab.example.com/group/proj/-/issues/42/?notes_filter=0',
                         @user, client: client).call

      assert_equal 42, client.calls.first[:iid]
    end

    # --- guards -----------------------------------------------------

    def test_raises_on_non_issue_url
      assert_raises(GitlabImporter::InvalidUrl) do
        GitlabImporter.new('https://gitlab.example.com/group/proj',
                           @user, client: stub_client).call
      end
    end

    def test_raises_when_project_not_in_db
      assert_raises(GitlabImporter::ProjectNotFound) do
        GitlabImporter.new('https://gitlab.example.com/other/proj/-/issues/1',
                           @user, client: stub_client).call
      end
    end

    def test_raises_when_user_has_no_access_to_project
      other_user = User.create!(email: 'other@modulotech.fr', name: 'Other')
      # other_user has no membership on @project
      assert_raises(GitlabImporter::ProjectNotVisible) do
        GitlabImporter.new('https://gitlab.example.com/group/proj/-/issues/1',
                           other_user, client: stub_client).call
      end
    end

    # Gitlab::Error::NotFound's constructor expects a real GitLab HTTP
    # response object — overkill to fabricate here. The importer's
    # rescue chain catches both NotFound and the broader Error
    # superclass, so raising the latter exercises the same IssueNotFound
    # outcome users would see in production.
    def test_raises_when_gitlab_api_errors_out
      client = stub_client(error: Gitlab::Error::Error.new('Not Found'))
      assert_raises(GitlabImporter::IssueNotFound) do
        GitlabImporter.new('https://gitlab.example.com/group/proj/-/issues/999',
                           @user, client: client).call
      end
    end

    def test_admin_user_can_import_without_membership
      admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
      draft = GitlabImporter.new('https://gitlab.example.com/group/proj/-/issues/1',
                                 admin, client: stub_client).call

      assert_equal admin, draft.user
    end
  end
end
