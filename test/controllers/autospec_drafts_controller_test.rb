# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# JSON-contract integration tests for the AutospecDrafts chat +
# apply_suggestion endpoints (phase D step 9c). The chat action uses
# the real `Autospec::Chat` service with a stubbed Anthropic client
# (injected via the `Autospec::Chat.default_client` class hook so the
# controller-side constructor call — which can't pass `client:`
# directly — still sees the stub). HTML redirect flow is covered by
# `autospec_drafts_html_test.rb`.
class AutospecDraftsControllerTest < ActionDispatch::IntegrationTest # rubocop:disable Metrics/ClassLength
  include Devise::Test::IntegrationHelpers

  StubClient = Struct.new(:response, :calls) do
    def messages = self
    def create(params) = (calls << params).then { response }
  end

  TextBlock = Struct.new(:type, :text)
  Response  = Struct.new(:content)

  setup do
    @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @other   = User.create!(email: 'other@modulotech.fr', name: 'Other')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
    @draft   = AutospecDraft.create!(user: @author, project: @project,
                                     title: 'Old', markdown: '# Spec')
  end

  teardown do
    Autospec::Chat.default_client = nil
    Autospec::GitlabSubmitter.disabled = false
  end

  def stub_chat_response(blocks)
    Autospec::Chat.default_client = StubClient.new(Response.new(blocks), [])
  end

  # --- chat (JSON) --------------------------------------------------

  def test_chat_requires_signed_in_user
    post "/autospec_drafts/#{@draft.id}/chat", params: { message: 'salut' }, as: :json

    assert_response :unauthorized
  end

  def test_chat_forbids_non_author
    sign_in @other
    post "/autospec_drafts/#{@draft.id}/chat", params: { message: 'salut' }, as: :json

    assert_response :forbidden
  end

  def test_chat_persists_user_and_assistant_messages
    sign_in @author
    stub_chat_response([TextBlock.new('text', 'Bonjour')])

    assert_difference '@draft.autospec_messages.count', 2 do
      post "/autospec_drafts/#{@draft.id}/chat", params: { message: 'salut' }, as: :json
    end
  end

  def test_chat_returns_assistant_message_payload
    sign_in @author
    stub_chat_response([TextBlock.new('text', 'Salut !')])
    post "/autospec_drafts/#{@draft.id}/chat", params: { message: 'salut' }, as: :json
    body = JSON.parse(response.body)

    assert_equal 'assistant', body.dig('message', 'role')
    assert_equal 'Salut !',   body.dig('message', 'content')
  end

  # --- create: auto quality evaluation (task #15) -------------------

  def member_author!
    ProjectMembership.create!(user: @author, project: @project, role: 'contributor')
  end

  def test_create_auto_evaluates_quality_when_content_present # rubocop:disable Metrics/AbcSize
    sign_in @author
    member_author!
    stub_chat_response([TextBlock.new('text', '🔴 Qualité : Insuffisante')])

    post '/autospec_drafts',
         params: { project_id: @project.id, title: 'test', markdown: 'Je veux un bouton.' }
    draft = AutospecDraft.order(:id).last
    messages = draft.autospec_messages.order(:id)

    assert_redirected_to "/autospec_drafts/#{draft.id}"
    # First turn = the auto-sent eval prompt (fr default locale), second =
    # the assistant assessment.
    assert_equal %w[user assistant], messages.pluck(:role)
    assert_equal 'Évalue la qualité du ticket.', messages.first.content
  end

  def test_create_skips_auto_eval_for_blank_draft
    sign_in @author
    member_author!
    stub_chat_response([TextBlock.new('text', 'should not be called')])

    post '/autospec_drafts', params: { project_id: @project.id, title: '', markdown: '' }
    draft = AutospecDraft.order(:id).last

    assert_redirected_to "/autospec_drafts/#{draft.id}"
    assert_equal 0, draft.autospec_messages.count
  end

  RaisingClient = Struct.new(:noop) do
    def messages = self
    def create(_params) = raise(StandardError, 'boom')
  end

  def test_create_auto_eval_failure_does_not_block_creation
    sign_in @author
    member_author!
    Autospec::Chat.default_client = RaisingClient.new

    assert_difference 'AutospecDraft.count', 1 do
      post '/autospec_drafts', params: { project_id: @project.id, title: 'test', markdown: 'x' }
    end
    assert_response :redirect
  end

  # --- apply_suggestion (JSON) --------------------------------------

  def title_tool(id: 'tu1', title: 'New')
    { 'type' => 'tool_use', 'id' => id, 'name' => 'propose_title',
      'input' => { 'title' => title, 'summary' => 'rename' } }
  end

  def assistant_with(tool_call)
    AutospecMessage.create!(autospec_draft: @draft, role: 'assistant',
                            content: 'sugg', tool_calls: [tool_call])
  end

  def test_apply_suggestion_requires_signed_in_user
    msg = assistant_with(title_tool)
    post "/autospec_drafts/#{@draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'tu1' }, as: :json

    assert_response :unauthorized
  end

  def test_apply_suggestion_forbids_non_author
    sign_in @other
    msg = assistant_with(title_tool)
    post "/autospec_drafts/#{@draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'tu1' }, as: :json

    assert_response :forbidden
  end

  def test_apply_suggestion_updates_draft
    sign_in @author
    msg = assistant_with(title_tool(title: 'Better'))
    post "/autospec_drafts/#{@draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'tu1' }, as: :json

    assert_equal 'Better', @draft.reload.title
  end

  def test_apply_suggestion_returns_updated_draft
    sign_in @author
    msg = assistant_with(title_tool(title: 'Renamed'))
    post "/autospec_drafts/#{@draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'tu1' }, as: :json

    assert_equal 'Renamed', JSON.parse(response.body).dig('draft', 'title')
  end

  def test_apply_suggestion_re_apply_returns_conflict
    sign_in @author
    msg = assistant_with(title_tool)
    post "/autospec_drafts/#{@draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'tu1' }, as: :json
    post "/autospec_drafts/#{@draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'tu1' }, as: :json

    assert_response :conflict
  end

  def test_apply_suggestion_unknown_tool_use_id_returns_not_found
    sign_in @author
    msg = assistant_with(title_tool)
    post "/autospec_drafts/#{@draft.id}/apply_suggestion",
         params: { message_id: msg.id, tool_use_id: 'nope' }, as: :json

    assert_response :not_found
  end

  # --- update (JSON) ------------------------------------------------

  def test_update_requires_signed_in_user
    patch "/autospec_drafts/#{@draft.id}", params: { title: 'X' }, as: :json

    assert_response :unauthorized
  end

  def test_update_forbids_non_author
    sign_in @other
    patch "/autospec_drafts/#{@draft.id}", params: { title: 'X' }, as: :json

    assert_response :forbidden
  end

  def test_update_persists_title_and_markdown
    sign_in @author
    patch "/autospec_drafts/#{@draft.id}",
          params: { title: 'New', markdown: '## Done' }, as: :json

    assert_response :success
    assert_equal ['New', '## Done'], [@draft.reload.title, @draft.markdown]
  end

  def test_update_persists_meta_chips
    sign_in @author
    patch "/autospec_drafts/#{@draft.id}",
          params: { meta_chips: { type: 'bug', priority: 'high', tags: %w[frontend ux] } },
          as: :json

    assert_equal({ 'type' => 'bug', 'priority' => 'high', 'tags' => %w[frontend ux] },
                 @draft.reload.meta_chips)
  end

  def test_update_drops_unknown_meta_keys
    sign_in @author
    patch "/autospec_drafts/#{@draft.id}",
          params: { meta_chips: { type: 'bug', destination: 'autodev', assignee: 'x' } },
          as: :json

    assert_equal({ 'type' => 'bug' }, @draft.reload.meta_chips)
  end

  def test_update_rejects_when_not_drafting
    sign_in @author
    @draft.submit_for_approval!
    patch "/autospec_drafts/#{@draft.id}", params: { title: 'X' }, as: :json

    assert_response :conflict
    assert_equal 'draft_locked', JSON.parse(response.body)['error']
  end

  def test_chat_returns_503_when_anthropic_key_missing
    sign_in @author
    # Don't install the default_client stub — falls through to env/config.
    # Clear any ambient ANTHROPIC_API_KEY (e.g. when the developer runs
    # the suite from a shell that exports it) so the test mirrors the
    # prod-without-key state deterministically.
    Autospec::Chat.default_client = nil
    previous_env = ENV.delete('ANTHROPIC_API_KEY')
    post "/autospec_drafts/#{@draft.id}/chat", params: { message: 'salut' }, as: :json

    assert_response :service_unavailable
    assert_equal 'chat_unavailable', JSON.parse(response.body)['error']
  ensure
    ENV['ANTHROPIC_API_KEY'] = previous_env if previous_env
  end

  # --- submit_for_approval (JSON) -----------------------------------

  def test_submit_requires_signed_in_user
    post "/autospec_drafts/#{@draft.id}/submit_for_approval",
         params: { destination: 'human' }, as: :json

    assert_response :unauthorized
  end

  def test_submit_forbids_non_author
    sign_in @other
    post "/autospec_drafts/#{@draft.id}/submit_for_approval",
         params: { destination: 'human' }, as: :json

    assert_response :forbidden
  end

  def test_submit_rejects_invalid_destination
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/submit_for_approval",
         params: { destination: 'banana' }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'destination_invalid', JSON.parse(response.body)['error']
  end

  def test_submit_with_human_destination_flips_status
    ProjectMembership.create!(user: @author, project: @project, role: 'contributor')
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/submit_for_approval",
         params: { destination: 'human' }, as: :json

    assert_response :success
    @draft.reload

    assert_equal 'pending_approval', @draft.status
    assert_equal 'human', @draft.destination
  end

  def test_submit_with_autodev_destination_blocked_for_contributor_author
    ProjectMembership.create!(user: @author, project: @project, role: 'contributor')
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/submit_for_approval",
         params: { destination: 'autodev' }, as: :json

    assert_response :forbidden
    assert_equal 'destination_forbidden', JSON.parse(response.body)['error']
  end

  def test_submit_with_autodev_destination_allowed_for_owner_author
    ProjectMembership.create!(user: @author, project: @project, role: 'owner')
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/submit_for_approval",
         params: { destination: 'autodev' }, as: :json

    assert_response :success
    assert_equal 'autodev', @draft.reload.destination
  end

  def test_submit_returns_conflict_when_not_drafting
    ProjectMembership.create!(user: @author, project: @project, role: 'owner')
    @draft.submit_for_approval!
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/submit_for_approval",
         params: { destination: 'human' }, as: :json

    assert_response :conflict
    assert_equal 'draft_not_drafting', JSON.parse(response.body)['error']
  end

  # --- retract (JSON) -----------------------------------------------

  def test_retract_forbids_non_author
    sign_in @other
    post "/autospec_drafts/#{@draft.id}/retract", as: :json

    assert_response :forbidden
  end

  def test_retract_returns_conflict_when_not_pending_approval
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/retract", as: :json

    assert_response :conflict
    assert_equal 'draft_not_pending_approval', JSON.parse(response.body)['error']
  end

  def test_retract_flips_status_back_to_drafting
    ProjectMembership.create!(user: @author, project: @project, role: 'owner')
    @draft.update!(destination: 'human')
    @draft.submit_for_approval!
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/retract", as: :json

    assert_response :success
    assert_equal 'drafting', @draft.reload.status
  end

  # --- approve / reject (JSON) --------------------------------------

  def submit_draft_for_approval!
    ProjectMembership.create!(user: @author, project: @project, role: 'owner')
    @draft.update!(destination: 'human')
    @draft.submit_for_approval!
  end

  def test_approve_requires_owner_role
    submit_draft_for_approval!
    ProjectMembership.create!(user: @other, project: @project, role: 'contributor')
    sign_in @other
    post "/autospec_drafts/#{@draft.id}/approve", as: :json

    assert_response :forbidden
  end

  def test_approve_finalizes_when_all_owners_approved
    Autospec::GitlabSubmitter.disabled = true # don't hit the GitLab API
    submit_draft_for_approval! # @author is the only owner — their vote finalises.
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/approve", as: :json

    assert_response :success
    assert_equal 'submitted', @draft.reload.status
  end

  def test_approve_returns_conflict_when_already_voted
    Autospec::GitlabSubmitter.disabled = true # the first vote finalises the draft
    submit_draft_for_approval!
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/approve", as: :json
    # second vote at same iteration — author is now the only owner
    # but the draft already finalised, so the "votable_by?" gate
    # returns 403 (not pending_approval any more).
    post "/autospec_drafts/#{@draft.id}/approve", as: :json

    assert_response :forbidden
  end

  def test_reject_requires_reason
    submit_draft_for_approval!
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/reject", params: { reason: '' }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'reason_required', JSON.parse(response.body)['error']
  end

  def test_reject_marks_draft_rejected
    submit_draft_for_approval!
    sign_in @author
    post "/autospec_drafts/#{@draft.id}/reject",
         params: { reason: 'pas assez précis' }, as: :json

    assert_response :success
    assert_equal 'rejected', @draft.reload.status
  end

  # --- show visibility per autospec.md §J ---------------------------

  def test_show_forbids_contributor_non_author
    ProjectMembership.create!(user: @other, project: @project, role: 'contributor')
    sign_in @other
    get "/autospec_drafts/#{@draft.id}", as: :json

    assert_response :forbidden
  end

  def test_show_forbids_owner_non_author_for_drafting_draft
    ProjectMembership.create!(user: @other, project: @project, role: 'owner')
    sign_in @other
    get "/autospec_drafts/#{@draft.id}", as: :json

    assert_response :forbidden
  end

  def test_show_allows_owner_non_author_for_pending_approval_draft
    ProjectMembership.create!(user: @author, project: @project, role: 'owner')
    ProjectMembership.create!(user: @other, project: @project, role: 'owner')
    @draft.update!(destination: 'human')
    @draft.submit_for_approval!
    sign_in @other
    get "/autospec_drafts/#{@draft.id}"

    assert_response :success
  end

  def test_update_returns_serialised_draft
    sign_in @author
    patch "/autospec_drafts/#{@draft.id}", params: { title: 'Updated' }, as: :json

    assert_equal 'Updated', JSON.parse(response.body).dig('draft', 'title')
  end
end
