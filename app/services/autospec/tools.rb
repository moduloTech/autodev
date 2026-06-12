# frozen_string_literal: true

# Tool schemas shipped to the Anthropic API on every AutoSpec chat turn.
# See autodev/docs/autospec.md §G for the protocol: the model emits
# `tool_use` blocks suggesting changes; the CSM clicks the matching apply
# button in the UI; the server applies the change locally and stamps
# `applied_at` on the persisted tool_call. The model NEVER executes a tool
# — synthetic `tool_result` blocks are constructed on the next request
# from those stamps (see `Autospec::MessageBuilder`).
#
# Discouragement of `propose_full_rewrite` lives in the tool description
# itself AND in the system prompt (`Autospec::SystemPrompt`). Keeping the
# discouragement in two places matches §G's recommendation — the model
# attends to both system + tool definitions when picking which tool to use.
module Autospec
  module Tools
    SUMMARY_MAX = 50

    MARKDOWN_PATCH = {
      name: 'propose_markdown_patch',
      description: <<~DESC.strip,
        Propose a surgical edit to the draft's markdown body. PREFER this tool
        for ~90% of edits: adding a section, replacing a section, appending a
        bullet, inserting a paragraph after a heading. Use
        `propose_full_rewrite` ONLY when the change is structural enough that
        no patch could express it.
      DESC
      input_schema: {
        type: 'object',
        properties: {
          operation: {
            type: 'string',
            enum: %w[insert_after_heading replace_section append_to_end create_section],
            description: 'How to apply the patch.'
          },
          target_heading: {
            type: 'string',
            description: 'The heading text to anchor the operation against. ' \
                         'Required for insert_after_heading, replace_section, create_section. ' \
                         'Match is case-insensitive + whitespace-trimmed; if not found the apply ' \
                         'falls back to append_to_end.'
          },
          content: {
            type: 'string',
            description: 'The markdown to insert / replace / append.'
          },
          summary: {
            type: 'string',
            maxLength: SUMMARY_MAX,
            description: 'Short label shown on the apply button (≤50 chars).'
          }
        },
        required: %w[operation content summary]
      }
    }.freeze

    FULL_REWRITE = {
      name: 'propose_full_rewrite',
      description: <<~DESC.strip,
        Propose a complete rewrite of the draft markdown. STRONGLY DISCOURAGED
        — `propose_markdown_patch` covers ~90% of real edits at lower risk and
        less cognitive load for the CSM. Only emit this when the existing
        structure has to change wholesale (heading reorganisation, scope
        pivot). `rationale` must explain why a patch wouldn't suffice.
      DESC
      input_schema: {
        type: 'object',
        properties: {
          content: { type: 'string', description: 'The full new markdown body.' },
          rationale: {
            type: 'string',
            description: 'Why a full rewrite is justified over a patch.'
          },
          summary: { type: 'string', maxLength: SUMMARY_MAX }
        },
        required: %w[content rationale summary]
      }
    }.freeze

    TITLE = {
      name: 'propose_title',
      description: 'Propose a new title for the draft. Use when the title needs to change ' \
                   'but the body does not.',
      input_schema: {
        type: 'object',
        properties: {
          title: { type: 'string', description: 'The new title.' },
          summary: { type: 'string', maxLength: SUMMARY_MAX }
        },
        required: %w[title summary]
      }
    }.freeze

    META_CHANGE = {
      name: 'propose_meta_change',
      description: 'Propose changes to draft metadata (type, priority, tags). Group ' \
                   'multiple changes into one call. No `assignee` field at the MVP — ' \
                   'assignment stays a human decision.',
      input_schema: {
        type: 'object',
        properties: {
          type: { type: 'string', description: 'New ticket type (e.g. bug / feature / improvement).' },
          priority: { type: 'string', description: 'New priority (e.g. low / medium / high / critical).' },
          tags: { type: 'array', items: { type: 'string' }, description: 'Replacement set of tags.' },
          summary: { type: 'string', maxLength: SUMMARY_MAX }
        },
        required: %w[summary]
      }
    }.freeze

    ALL = [MARKDOWN_PATCH, FULL_REWRITE, TITLE, META_CHANGE].freeze
    NAMES = ALL.map { |t| t[:name] }.freeze
  end
end
