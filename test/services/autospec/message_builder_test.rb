# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class MessageBuilderTest < ActiveSupport::TestCase
    setup do
      @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
      @draft   = AutospecDraft.create!(user: @user, project: @project)
    end

    def add_user(content)
      AutospecMessage.create!(autospec_draft: @draft, role: 'user', content: content)
    end

    def add_assistant(content, tool_calls = [])
      AutospecMessage.create!(autospec_draft: @draft, role: 'assistant',
                              content: content, tool_calls: tool_calls)
    end

    def tool_use(id:, name: 'propose_markdown_patch', input: {}, applied_at: nil)
      block = { 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }
      block['applied_at'] = applied_at if applied_at
      block
    end

    def test_empty_history_returns_empty_array
      assert_empty Autospec::MessageBuilder.build(@draft)
    end

    def test_single_user_turn
      add_user('Bonjour')
      result = Autospec::MessageBuilder.build(@draft)

      assert_equal 1, result.size
      assert_equal 'user', result.first[:role]
      assert_equal [{ type: 'text', text: 'Bonjour' }], result.first[:content]
    end

    def test_assistant_turn_emits_tool_use_blocks
      add_user('Bonjour')
      add_assistant('Voici ma suggestion',
                    [tool_use(id: 'toolu_01', input: { 'operation' => 'append_to_end' })])

      last = Autospec::MessageBuilder.build(@draft).last

      assert_equal 'assistant', last[:role]
      assert_equal 'tool_use', last[:content].last[:type]
      assert_equal 'toolu_01', last[:content].last[:id]
    end

    def test_user_turn_after_assistant_prepends_synthetic_tool_results
      add_user('Bonjour')
      add_assistant('Suggestion', [tool_use(id: 'toolu_01')])
      add_user('Merci')
      synthetic = Autospec::MessageBuilder.build(@draft).last[:content].first

      assert_equal({ type: 'tool_result', tool_use_id: 'toolu_01',
                     content: 'User has not applied this suggestion.' },
                   synthetic)
    end

    def test_applied_tool_use_yields_applied_synthetic_result
      add_user('Bonjour')
      add_assistant('Suggestion', [tool_use(id: 'toolu_01', applied_at: '2026-06-12T10:00:00Z')])
      add_user('Merci')

      result_text = Autospec::MessageBuilder.build(@draft).last[:content].first[:content]

      assert_equal 'Applied by user at 2026-06-12T10:00:00Z.', result_text
    end

    def test_multiple_tool_uses_yield_multiple_synthetic_results
      add_user('Bonjour')
      add_assistant('Two suggestions',
                    [tool_use(id: 'toolu_01'), tool_use(id: 'toolu_02', applied_at: '2026-06-12T10:00:00Z')])
      add_user('Suite')
      tool_results = Autospec::MessageBuilder.build(@draft).last[:content]
                                             .select { |b| b[:type] == 'tool_result' }

      assert_equal(%w[toolu_01 toolu_02], tool_results.map { |b| b[:tool_use_id] })
    end

    def test_assistant_without_text_emits_only_tool_use
      add_user('Bonjour')
      add_assistant(nil, [tool_use(id: 'toolu_01')])

      last = Autospec::MessageBuilder.build(@draft).last

      assert(last[:content].none? { |b| b[:type] == 'text' })
      assert_equal 1, last[:content].size
    end
  end
end
