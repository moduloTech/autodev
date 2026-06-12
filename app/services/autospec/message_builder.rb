# frozen_string_literal: true

module Autospec
  # Builds the `messages:` array for an Anthropic Messages API call from
  # the AR conversation log on an AutospecDraft. The interesting part is
  # the synthesis of `tool_result` blocks (cf. autodev/docs/autospec.md §G
  # "Tool results synthétiques").
  #
  # Why synthetic: the Anthropic API requires every `tool_use` from an
  # assistant turn to be followed by a `tool_result` (referencing the
  # same `tool_use_id`) in the next user turn. But in AutoSpec the *user*
  # applies tool suggestions — not the model — so there is no natural
  # payload to return. We invent one from the `applied_at` stamp the
  # SuggestionApplier writes on the persisted tool_call:
  #
  #   - `applied_at` present → "Applied by user at <iso>."
  #   - `applied_at` nil     → "User has not applied this suggestion."
  #
  # This is "strict feedback" (per §G): the model is told *factually*
  # whether each suggestion landed, and adapts the next turn accordingly
  # (if it sees a chain of unapplied suggestions, it pivots to clarifying
  # questions instead of doubling down on more patches).
  module MessageBuilder
    module_function

    RESULT_APPLIED_FORMAT     = 'Applied by user at %s.'
    RESULT_NOT_APPLIED_STRING = 'User has not applied this suggestion.'

    # Returns an array of message hashes shaped for the Anthropic API.
    # Pass the AR draft directly — we walk autospec_messages in :id order
    # so iteration / approval-state changes are irrelevant here, only
    # the chat sequence matters.
    def build(draft)
      previous_tool_calls = nil
      draft.autospec_messages.order(:id).map do |msg|
        turn = build_turn(msg, previous_tool_calls)
        previous_tool_calls = msg.role == AutospecMessage::ROLE_USER ? nil : msg.tool_calls
        turn
      end
    end

    def build_turn(msg, previous_tool_calls)
      msg.role == AutospecMessage::ROLE_USER ? build_user_turn(msg, previous_tool_calls) : build_assistant_turn(msg)
    end

    def build_user_turn(msg, previous_tool_calls)
      blocks = Array(previous_tool_calls).map do |call|
        { type: 'tool_result', tool_use_id: call['id'],
          content: synth_tool_result(call) }
      end
      blocks << { type: 'text', text: msg.content } if msg.content.present?
      { role: 'user', content: blocks }
    end

    def build_assistant_turn(msg)
      blocks = []
      blocks << { type: 'text', text: msg.content } if msg.content.present?
      Array(msg.tool_calls).each do |call|
        blocks << { type: 'tool_use', id: call['id'],
                    name: call['name'], input: call['input'] }
      end
      { role: 'assistant', content: blocks }
    end

    def synth_tool_result(tool_call)
      if tool_call['applied_at']
        format(RESULT_APPLIED_FORMAT, tool_call['applied_at'])
      else
        RESULT_NOT_APPLIED_STRING
      end
    end
  end
end
