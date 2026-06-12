# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class SuggestionApplierTest < ActiveSupport::TestCase
    setup do
      @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
      @draft   = AutospecDraft.create!(user: @user, project: @project,
                                       title: 'Old title', markdown: '# Spec', meta_chips: {})
    end

    def assistant_message(tool_calls)
      AutospecMessage.create!(autospec_draft: @draft, role: 'assistant',
                              content: 'suggestion', tool_calls: tool_calls)
    end

    def tool_call(id:, name:, input:)
      { 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }
    end

    def test_applies_propose_title
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_title',
                                         input: { 'title' => 'New', 'summary' => 'rename' })])
      SuggestionApplier.new(msg, 'tu1').call

      assert_equal 'New', @draft.reload.title
    end

    def test_applies_propose_full_rewrite
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_full_rewrite',
                                         input: { 'content' => '# Brand new', 'rationale' => 'r',
                                                  'summary' => 's' })])
      SuggestionApplier.new(msg, 'tu1').call

      assert_equal '# Brand new', @draft.reload.markdown
    end

    def test_applies_propose_meta_change_merges
      @draft.update!(meta_chips: { 'tags' => ['old'] })
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_meta_change',
                                         input: { 'priority' => 'high', 'summary' => 's' })])
      SuggestionApplier.new(msg, 'tu1').call

      assert_equal({ 'tags' => ['old'], 'priority' => 'high' }, @draft.reload.meta_chips)
    end

    def test_applies_propose_markdown_patch_append
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_markdown_patch',
                                         input: { 'operation' => 'append_to_end',
                                                  'content' => '- new bullet', 'summary' => 's' })])
      SuggestionApplier.new(msg, 'tu1').call

      assert_match(/- new bullet/, @draft.reload.markdown)
    end

    def test_patch_fell_back_when_heading_missing
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_markdown_patch',
                                         input: { 'operation' => 'insert_after_heading',
                                                  'target_heading' => 'inexistant',
                                                  'content' => 'x', 'summary' => 's' })])
      result = SuggestionApplier.new(msg, 'tu1').call

      assert_predicate result, :fell_back?
    end

    def test_stamps_applied_at_after_apply
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_title',
                                         input: { 'title' => 'X', 'summary' => 's' })])
      SuggestionApplier.new(msg, 'tu1').call

      assert msg.reload.tool_calls.first['applied_at']
    end

    def test_idempotent_refuses_re_apply
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_title',
                                         input: { 'title' => 'X', 'summary' => 's' })])
      SuggestionApplier.new(msg, 'tu1').call

      assert_raises(SuggestionApplier::AlreadyApplied) do
        SuggestionApplier.new(msg.reload, 'tu1').call
      end
    end

    def test_unknown_tool_use_id_raises
      msg = assistant_message([tool_call(id: 'tu1', name: 'propose_title',
                                         input: { 'title' => 'X', 'summary' => 's' })])

      assert_raises(SuggestionApplier::ToolUseNotFound) do
        SuggestionApplier.new(msg, 'nope').call
      end
    end

    def test_unsupported_tool_name_raises
      msg = assistant_message([tool_call(id: 'tu1', name: 'imaginary_tool',
                                         input: { 'summary' => 's' })])

      assert_raises(SuggestionApplier::UnsupportedTool) do
        SuggestionApplier.new(msg, 'tu1').call
      end
    end
  end
end
