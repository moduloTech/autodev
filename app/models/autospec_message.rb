# frozen_string_literal: true

# One turn in an AutospecDraft's conversation. See autodev/docs/autospec.md
# §G for the tool-call protocol that lives inside `tool_calls`.
#
# Roles follow Anthropic's API vocabulary: 'user' (CSM input) and
# 'assistant' (model output, may carry `tool_use` blocks in `tool_calls`).
# The Anthropic SDK uses no 'tool' role — `tool_result` blocks live
# *inside* the next user turn's content array; we DON'T persist those
# synthetic blocks (the AutospecChat service rebuilds them on every
# request from the `applied_at` stamps inside `tool_calls`).
class AutospecMessage < ApplicationRecord
  ROLE_USER      = 'user'
  ROLE_ASSISTANT = 'assistant'
  ROLES          = [ROLE_USER, ROLE_ASSISTANT].freeze

  # `t.json :tool_calls` maps to SQLite TEXT — the :json attribute wires
  # Array ↔ JSON round-trip transparently. Same pattern as
  # AutospecDraft#meta_chips and AuditLog#payload.
  attribute :tool_calls, :json, default: []

  belongs_to :autospec_draft

  validates :role, inclusion: { in: ROLES }
end
