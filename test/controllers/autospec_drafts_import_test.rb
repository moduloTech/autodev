# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# HTTP-flow tests for the AutoSpec import path (phase D step 12).
# GET /autospec_drafts/import renders the form; POST creates a draft
# via Autospec::GitlabImporter. Service-level concerns (URL parsing,
# visibility, error mapping) are covered by gitlab_importer_test.rb;
# this file is the HTTP contract.
class AutospecDraftsImportTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  StubClient = Struct.new(:response, :calls) do
    def issue(project_path, iid)
      calls << { project: project_path, iid: iid }
      response
    end
  end

  IssueResponse = Struct.new(:title, :description)

  setup do
    @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    ProjectMembership.create!(user: @author, project: @project, role: 'contributor')

    Autospec::GitlabImporter.default_client = StubClient.new(
      IssueResponse.new('Bug from GitLab', 'Body from GitLab'), []
    )
  end

  teardown do
    Autospec::GitlabImporter.default_client = nil
  end

  # --- GET /autospec_drafts/import --------------------------------

  def test_import_requires_signed_in_user
    get '/autospec_drafts/import'

    assert_response :redirect
  end

  def test_import_form_renders_for_signed_in_user
    sign_in @author
    get '/autospec_drafts/import'

    assert_response :success
    assert_includes response.body, 'Importer un ticket GitLab'
  end

  # --- POST /autospec_drafts/import -------------------------------

  def test_create_from_import_creates_draft_and_redirects_to_show
    sign_in @author

    assert_difference 'AutospecDraft.count', 1 do
      post '/autospec_drafts/import',
           params: { url: 'https://gitlab.example.com/group/proj/-/issues/42' }
    end
    assert_match(%r{/autospec_drafts/\d+}, response.location)
    assert_equal 'Bug from GitLab', AutospecDraft.last.title
  end

  def test_create_from_import_redirects_back_on_invalid_url
    sign_in @author
    post '/autospec_drafts/import', params: { url: 'not a url' }

    assert_response :redirect
    assert_equal '/autospec_drafts/import', URI.parse(response.location).path
    assert_equal 'import_invalid_url', flash[:alert]
  end

  def test_create_from_import_redirects_back_on_unknown_project
    sign_in @author
    post '/autospec_drafts/import',
         params: { url: 'https://gitlab.example.com/unknown/proj/-/issues/1' }

    assert_response :redirect
    assert_equal 'import_project_not_found', flash[:alert]
  end

  def test_create_from_import_redirects_back_on_invisible_project
    invisible = Project.create!(gitlab_path: 'other/proj', slug: 'other__proj')
    sign_in @author
    post '/autospec_drafts/import',
         params: { url: "https://gitlab.example.com/#{invisible.gitlab_path}/-/issues/1" }

    assert_response :redirect
    assert_equal 'import_project_not_visible', flash[:alert]
  end
end
