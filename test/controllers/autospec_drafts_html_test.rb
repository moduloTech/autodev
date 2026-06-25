# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# HTML-flow integration tests for the AutospecDrafts controller
# (step 10a — index / new / create / show + the redirect path of
# chat & apply_suggestion). The JSON contract lives in
# `autospec_drafts_controller_test.rb`.
class AutospecDraftsHtmlTest < ActionDispatch::IntegrationTest # rubocop:disable Metrics/ClassLength
  include Devise::Test::IntegrationHelpers

  StubClient = Struct.new(:response, :calls) do
    def messages = self
    def create(params) = (calls << params).then { response }
  end

  TextBlock = Struct.new(:type, :text)
  Response  = Struct.new(:content)

  # Stub for the GitLab client the importer uses (#issue → title/description).
  GitlabStub = Struct.new(:issue_obj) do
    def issue(_path, _iid) = issue_obj
  end
  ImportIssue = Struct.new(:title, :description)

  setup do
    @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @other   = User.create!(email: 'other@modulotech.fr', name: 'Other')
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    ProjectMembership.create!(user: @author, project: @project, role: 'contributor')
  end

  teardown do
    Autospec::Chat.default_client = nil
    Autospec::GitlabImporter.default_client = nil
  end

  # --- index --------------------------------------------------------

  def test_index_requires_signed_in_user
    get '/autospec_drafts'

    assert_response :redirect
  end

  def test_index_lists_only_current_user_drafts
    other_project = Project.create!(gitlab_path: 'other/proj', slug: 'other__proj')
    AutospecDraft.create!(user: @author, project: @project, title: 'Mine')
    AutospecDraft.create!(user: @other,  project: other_project, title: 'Not mine')
    sign_in @author
    get '/autospec_drafts'

    assert_response :success
    assert_includes response.body, 'Mine'
    refute_includes response.body, 'Not mine'
  end

  def test_index_empty_state_for_first_visit
    sign_in @author
    get '/autospec_drafts'

    assert_includes response.body, 'AutoSpec'
  end

  # --- new + create -------------------------------------------------

  def test_new_lists_visible_projects_only
    other_project = Project.create!(gitlab_path: 'other/proj', slug: 'other__proj')
    sign_in @author
    get '/autospec_drafts/new'

    assert_response :success
    assert_includes response.body, 'group/proj'
    refute_includes response.body, other_project.gitlab_path
  end

  def test_create_with_visible_project_persists_and_redirects
    sign_in @author

    assert_difference 'AutospecDraft.count', 1 do
      post '/autospec_drafts', params: { project_id: @project.id, title: 'A new bug' }
    end
    assert_response :redirect
    assert_match(%r{/autospec_drafts/\d+}, response.location)
  end

  def test_new_embeds_project_templates_for_the_picker
    @project.ticket_templates.create!(name: 'Évolution', slug: 'evolution', body: '## Localisation')
    sign_in @author
    get '/autospec_drafts/new'

    assert_response :success
    assert_includes response.body, 'autospec-templates-data'
    assert_includes response.body, 'Localisation'
  end

  def test_create_applies_chosen_template_body_when_markdown_blank
    tpl = @project.ticket_templates.create!(name: 'Évolution', slug: 'evolution', body: "## Localisation\n## Contexte")
    sign_in @author
    post '/autospec_drafts', params: { project_id: @project.id, template_slug: 'evolution' }
    draft = AutospecDraft.order(:id).last

    assert_response :redirect
    assert_equal "## Localisation\n## Contexte", draft.markdown
    # the chosen template is recorded so AutoSpec verifies against it (task #14 follow-up)
    assert_equal tpl.id, draft.ticket_template_id
  end

  def test_create_rejects_project_outside_visibility
    other_project = Project.create!(gitlab_path: 'other/proj', slug: 'other__proj')
    sign_in @author

    assert_no_difference 'AutospecDraft.count' do
      post '/autospec_drafts', params: { project_id: other_project.id, title: 'X' }
    end
    assert_response :redirect
    assert_equal '/autospec_drafts/new', URI.parse(response.location).path
  end

  # --- import + auto-evaluation (task #15 over the import path) ------

  def test_import_creates_draft_and_auto_evaluates_quality # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    Autospec::GitlabImporter.default_client = GitlabStub.new(ImportIssue.new('Login bug', '## Steps'))
    Autospec::Chat.default_client = StubClient.new(Response.new([TextBlock.new('text', '🔴 Insuffisante')]), [])
    sign_in @author

    post '/autospec_drafts/import',
         params: { url: 'https://gitlab.example.com/group/proj/-/work_items/1380' }
    draft = AutospecDraft.order(:id).last

    assert_redirected_to "/autospec_drafts/#{draft.id}"
    assert_equal 'Login bug', draft.title
    # imported draft has content → the quality eval runs: user prompt + assistant turn
    assert_equal %w[user assistant], draft.autospec_messages.order(:id).pluck(:role)
    assert_equal 'Évalue la qualité du ticket.', draft.autospec_messages.order(:id).first.content
  end

  # --- show ---------------------------------------------------------

  def test_show_renders_draft_for_author
    draft = AutospecDraft.create!(user: @author, project: @project,
                                  title: 'Login bug', markdown: '## Steps')
    sign_in @author
    get "/autospec_drafts/#{draft.id}"

    assert_response :success
    assert_includes response.body, 'Login bug'
    assert_includes response.body, '## Steps'
  end

  def test_show_forbids_non_author
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'Mine')
    sign_in @other
    get "/autospec_drafts/#{draft.id}"

    assert_response :forbidden
  end

  def test_show_renders_messages
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'X')
    AutospecMessage.create!(autospec_draft: draft, role: 'user', content: 'Bonjour Autodev')
    AutospecMessage.create!(autospec_draft: draft, role: 'assistant', content: 'Bonjour CSM')
    sign_in @author
    get "/autospec_drafts/#{draft.id}"

    assert_includes response.body, 'Bonjour Autodev'
    assert_includes response.body, 'Bonjour CSM'
  end

  # --- show: chat_enabled state -------------------------------------

  def test_show_disables_composer_when_anthropic_key_missing # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'X')
    sign_in @author
    Autospec::Chat.default_client = nil
    previous_env = ENV.delete('ANTHROPIC_API_KEY')
    saved_cfg = Web.config
    Web.config = (Web.config || {}).deep_dup.tap { |c| c.delete('anthropic') }
    get "/autospec_drafts/#{draft.id}"

    assert_match(/<textarea[^>]*name="message"[^>]*disabled/, response.body)
    assert_includes response.body, 'Chat indisponible'
  ensure
    ENV['ANTHROPIC_API_KEY'] = previous_env if previous_env
    Web.config = saved_cfg
  end

  def test_show_enables_composer_when_anthropic_key_present
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'X')
    Autospec::Chat.default_client = StubClient.new(Response.new([]), [])
    sign_in @author
    get "/autospec_drafts/#{draft.id}"

    refute_match(/<textarea[^>]*name="message"[^>]*disabled/, response.body)
  end

  # --- chat redirect flow -------------------------------------------

  def test_chat_html_redirects_to_show
    Autospec::Chat.default_client = StubClient.new(Response.new([TextBlock.new('text', 'Hi')]), [])
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'X')
    sign_in @author
    post "/autospec_drafts/#{draft.id}/chat", params: { message: 'salut' }

    assert_response :redirect
    assert_equal "/autospec_drafts/#{draft.id}", URI.parse(response.location).path
  end

  # --- apply_suggestion redirect flow -------------------------------

  def title_tool_assistant(draft)
    tool = { 'type' => 'tool_use', 'id' => 'tu1', 'name' => 'propose_title',
             'input' => { 'title' => 'New', 'summary' => 'rename' } }
    AutospecMessage.create!(autospec_draft: draft, role: 'assistant',
                            content: 'sugg', tool_calls: [tool])
  end

  def test_apply_suggestion_html_redirects_to_show
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'Old')
    msg = title_tool_assistant(draft)
    sign_in @author
    post "/autospec_drafts/#{draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'tu1' }

    assert_response :redirect
    assert_equal "/autospec_drafts/#{draft.id}", URI.parse(response.location).path
    assert_equal 'New', draft.reload.title
  end

  # --- submit/retract buttons in Show -------------------------------

  def test_show_renders_single_submit_button_for_contributor_author
    # setup already creates the contributor membership.
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'X')
    sign_in @author
    get "/autospec_drafts/#{draft.id}"

    assert_includes response.body, 'Envoyer à un dev'
    refute_includes response.body, 'Envoyer à AutoDev'
  end

  def test_show_renders_both_submit_buttons_for_owner_author
    @author.project_memberships.find_by(project: @project).update!(role: 'owner')
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'X')
    sign_in @author
    get "/autospec_drafts/#{draft.id}"

    assert_includes response.body, 'Envoyer à un dev'
    assert_includes response.body, 'Envoyer à AutoDev'
  end

  def test_show_renders_retract_button_when_pending_approval
    @author.project_memberships.find_by(project: @project).update!(role: 'owner')
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'X',
                                  destination: 'human')
    draft.submit_for_approval!
    sign_in @author
    get "/autospec_drafts/#{draft.id}"

    assert_includes response.body, 'Rétracter'
    refute_includes response.body, 'Envoyer à un dev'
  end

  # --- update redirect flow -----------------------------------------

  def test_update_html_redirects_to_show
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'Old')
    sign_in @author
    patch "/autospec_drafts/#{draft.id}", params: { title: 'New' }

    assert_response :redirect
    assert_equal "/autospec_drafts/#{draft.id}", URI.parse(response.location).path
    assert_equal 'New', draft.reload.title
  end

  def test_update_html_locked_draft_redirects_with_alert
    draft = AutospecDraft.create!(user: @author, project: @project, title: 'Old')
    draft.submit_for_approval!
    sign_in @author
    patch "/autospec_drafts/#{draft.id}", params: { title: 'X' }

    assert_response :redirect
    assert_equal 'draft_locked', flash[:alert]
    assert_equal 'Old', draft.reload.title
  end
end
