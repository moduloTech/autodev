# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class SystemPromptTest < ActiveSupport::TestCase
    setup do
      @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
      @draft   = AutospecDraft.create!(user: @user, project: @project,
                                       title: 'Bug login', markdown: '## Problème')
    end

    def test_persona_and_guidance_is_non_trivial
      text = Autospec::SystemPrompt.persona_and_guidance

      assert_operator text.length, :>, 200
      assert_match(/AutoSpec/, text)
    end

    def test_persona_warns_against_full_rewrite
      assert_match(/last resort|DISCOURAGED/i, Autospec::SystemPrompt.persona_and_guidance)
    end

    def test_draft_state_includes_title_and_markdown
      state = Autospec::SystemPrompt.draft_state(@draft)

      assert_match(/Bug login/, state)
      assert_match(/## Problème/, state)
    end

    def test_draft_state_renders_none_for_empty_fields
      blank_draft = AutospecDraft.create!(user: @user, project: @project)
      state = Autospec::SystemPrompt.draft_state(blank_draft)

      assert_match(/\(none yet\)/, state)
      assert_match(/\(empty\)/,    state)
    end

    def test_build_returns_two_blocks
      blocks = Autospec::SystemPrompt.build(@draft)

      assert_equal 2, blocks.size
      assert_equal 'text', blocks[0][:type]
      assert_equal 'text', blocks[1][:type]
    end

    def test_first_block_is_cache_tagged
      blocks = Autospec::SystemPrompt.build(@draft)

      assert_equal({ type: 'ephemeral' }, blocks[0][:cache_control])
    end

    def test_second_block_is_not_cache_tagged
      blocks = Autospec::SystemPrompt.build(@draft)

      refute blocks[1].key?(:cache_control)
    end

    # --- project briefing (3rd block, optional) -------------------

    def test_build_inserts_briefing_block_when_project_has_one
      @project.update!(briefing_text: "# Project briefing\n\nDomain: invoices.",
                       briefing_generated_at: Time.current)
      blocks = Autospec::SystemPrompt.build(@draft)

      assert_equal 3, blocks.size
      assert_match(/Project briefing/, blocks[1][:text])
      assert_equal({ type: 'ephemeral' }, blocks[1][:cache_control])
    end

    def test_build_omits_briefing_block_when_briefing_blank
      @project.update!(briefing_text: nil)
      blocks = Autospec::SystemPrompt.build(@draft)

      assert_equal 2, blocks.size
    end

    def test_briefing_block_carries_generated_at_marker
      ts = Time.utc(2026, 6, 16, 12, 0, 0)
      @project.update!(briefing_text: 'briefing body', briefing_generated_at: ts)
      blocks = Autospec::SystemPrompt.build(@draft)

      assert_includes blocks[1][:text], '2026-06-16T12:00:00Z'
    end
  end
end
