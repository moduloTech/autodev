# frozen_string_literal: true

require_relative '../rails_helper'

class AutospecMessageTest < ActiveSupport::TestCase
  setup do
    @user    = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
    @draft   = AutospecDraft.create!(user: @user, project: @project)
  end

  def test_draft_required
    refute_predicate AutospecMessage.new(role: 'user', content: 'hi'), :valid?
  end

  def test_role_inclusion
    msg = AutospecMessage.new(autospec_draft: @draft, role: 'system', content: 'no')

    refute_predicate msg, :valid?
    assert_includes msg.errors[:role], 'is not included in the list'
  end

  def test_user_and_assistant_roles_accepted
    %w[user assistant].each do |role|
      msg = AutospecMessage.new(autospec_draft: @draft, role: role, content: 'ok')

      assert_predicate msg, :valid?
    end
  end

  TOOL_CALL_FIXTURE = [{
    'type' => 'tool_use', 'id' => 'toolu_01abc', 'name' => 'propose_markdown_patch',
    'input' => { 'operation' => 'append_to_end', 'content' => 'extra' },
    'applied_at' => '2026-06-12T10:00:00Z'
  }].freeze

  def test_tool_calls_round_trips_as_array
    AutospecMessage.create!(autospec_draft: @draft, role: 'assistant',
                            content: 'sure', tool_calls: TOOL_CALL_FIXTURE)

    assert_equal TOOL_CALL_FIXTURE, AutospecMessage.last.tool_calls
  end

  def test_default_tool_calls_is_empty_array
    msg = AutospecMessage.create!(autospec_draft: @draft, role: 'user', content: 'hi')

    assert_equal [], msg.tool_calls
  end

  def test_belongs_to_draft
    msg = AutospecMessage.create!(autospec_draft: @draft, role: 'user', content: 'hello')

    assert_equal @draft, msg.autospec_draft
  end
end
