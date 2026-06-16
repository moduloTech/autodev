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

  def test_update_returns_serialised_draft
    sign_in @author
    patch "/autospec_drafts/#{@draft.id}", params: { title: 'Updated' }, as: :json

    assert_equal 'Updated', JSON.parse(response.body).dig('draft', 'title')
  end
end
