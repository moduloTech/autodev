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
class AutospecDraftsControllerTest < ActionDispatch::IntegrationTest
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
end
