# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class ChatTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
    # Tiny stand-in for Anthropic::Resources::Messages — captures the
    # params passed to `create` and returns a canned `content` array.
    StubClient = Struct.new(:response, :calls) do
      def messages
        self
      end

      def create(params)
        calls << params
        response
      end
    end

    TextBlock    = Struct.new(:type, :text)
    ToolUseBlock = Struct.new(:type, :id, :name, :input)
    Response     = Struct.new(:content)

    setup do
      @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p',
                                 default_locale: 'fr')
      @draft   = AutospecDraft.create!(user: @user, project: @project)
    end

    def stub_client(blocks)
      StubClient.new(Response.new(blocks), [])
    end

    def text(content)
      TextBlock.new('text', content)
    end

    def tool_use(id:, name: 'propose_title', input: { 'title' => 'New' })
      ToolUseBlock.new('tool_use', id, name, input)
    end

    def test_reply_persists_user_message
      chat = Autospec::Chat.new(@draft, client: stub_client([text('OK')]))
      chat.reply(user_content: 'Bonjour')

      assert_equal 'Bonjour', @draft.autospec_messages.where(role: 'user').last.content
    end

    def test_reply_persists_assistant_message
      chat = Autospec::Chat.new(@draft, client: stub_client([text('Salut')]))
      chat.reply(user_content: 'Bonjour')

      assistant = @draft.autospec_messages.where(role: 'assistant').last

      assert_equal 'Salut', assistant.content
    end

    def test_reply_returns_the_assistant_message
      chat   = Autospec::Chat.new(@draft, client: stub_client([text('Hi')]))
      result = chat.reply(user_content: 'Hello')

      assert_instance_of AutospecMessage, result
      assert_equal 'assistant', result.role
    end

    def reply_with(blocks, user_content: 'Aide-moi')
      Autospec::Chat.new(@draft, client: stub_client(blocks)).reply(user_content: user_content)
      @draft.autospec_messages.where(role: 'assistant').last
    end

    def test_assistant_message_holds_tool_use_in_tool_calls
      assistant = reply_with([text('Voici une suggestion'), tool_use(id: 'toolu_01')])

      assert_equal 1, assistant.tool_calls.size
      assert_equal 'toolu_01', assistant.tool_calls.first['id']
      assert_equal 'propose_title', assistant.tool_calls.first['name']
    end

    def test_request_carries_system_messages_and_tools
      client = stub_client([text('OK')])
      Autospec::Chat.new(@draft, client: client).reply(user_content: 'salut')

      params = client.calls.first

      assert_equal 'claude-sonnet-4-6', params[:model]
      assert_kind_of Array, params[:system]
      assert_equal Autospec::Tools::ALL, params[:tools]
    end

    def test_system_param_has_cache_control_on_first_block
      client = stub_client([text('OK')])
      Autospec::Chat.new(@draft, client: client).reply(user_content: 'salut')
      first_block = client.calls.first[:system].first

      assert_equal({ type: 'ephemeral' }, first_block[:cache_control])
    end

    def test_messages_param_includes_the_user_turn
      client = stub_client([text('OK')])
      Autospec::Chat.new(@draft, client: client).reply(user_content: 'Bonjour Claude')

      user_turn = client.calls.first[:messages].last

      assert_equal 'user', user_turn[:role]
      assert(user_turn[:content].any? { |b| b[:type] == 'text' && b[:text] == 'Bonjour Claude' })
    end

    def test_text_only_response_yields_empty_tool_calls
      chat = Autospec::Chat.new(@draft, client: stub_client([text('Ok')]))
      chat.reply(user_content: 'salut')

      assert_empty @draft.autospec_messages.where(role: 'assistant').last.tool_calls
    end

    def test_tool_use_input_is_stringified
      tool = ToolUseBlock.new('tool_use', 'toolu_01', 'propose_meta_change', { priority: 'high' })
      chat = Autospec::Chat.new(@draft, client: stub_client([tool]))
      chat.reply(user_content: 'Set high priority')

      input = @draft.autospec_messages.where(role: 'assistant').last.tool_calls.first['input']

      assert_equal({ 'priority' => 'high' }, input)
    end

    # --- api_key_configured? -----------------------------------------

    def test_api_key_configured_true_when_default_client_set
      Autospec::Chat.default_client = stub_client([text('hi')])

      assert_predicate Autospec::Chat, :api_key_configured?
    ensure
      Autospec::Chat.default_client = nil
    end

    def test_api_key_configured_true_when_env_var_set
      Autospec::Chat.default_client = nil
      with_env('ANTHROPIC_API_KEY' => 'sk-fake') do
        with_web_config(nil) do
          assert_predicate Autospec::Chat, :api_key_configured?
        end
      end
    end

    def test_api_key_configured_true_when_web_config_set
      Autospec::Chat.default_client = nil
      with_env('ANTHROPIC_API_KEY' => nil) do
        with_web_config({ 'anthropic' => { 'api_key' => 'sk-fake' } }) do
          assert_predicate Autospec::Chat, :api_key_configured?
        end
      end
    end

    def test_api_key_configured_false_when_nothing_set
      Autospec::Chat.default_client = nil
      with_env('ANTHROPIC_API_KEY' => nil) do
        with_web_config(nil) do
          refute_predicate Autospec::Chat, :api_key_configured?
        end
      end
    end

    private

    def with_env(vars)
      previous = vars.each_with_object({}) { |(k, _), h| h[k] = ENV.fetch(k, :__unset__) }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      previous.each do |k, v|
        v == :__unset__ ? ENV.delete(k) : ENV[k] = v
      end
    end

    def with_web_config(config)
      previous = ::Web.respond_to?(:config) ? ::Web.config : nil
      ::Web.config = config
      yield
    ensure
      ::Web.config = previous
    end
  end
end
