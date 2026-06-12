# frozen_string_literal: true

module Autospec
  # Builds the `system` parameter for an Anthropic Messages API call.
  #
  # Two blocks (cf. autodev/docs/autospec.md §G "System prompt cacheable"):
  #
  #   1. persona + tool-usage guidance — stable across the entire session,
  #      tagged `cache_control: { type: 'ephemeral' }` so Anthropic caches
  #      it for the 5-minute TTL and subsequent turns in the same chat
  #      hit the cache.
  #   2. draft state (title + markdown + meta_chips) — changes whenever
  #      the CSM edits, so we don't cache it. §G notes this could ALSO
  #      be cached as a second breakpoint if measurements show the cost
  #      matters; left as an optimisation for later (one extra
  #      `cache_control` line + a cache-key invalidation on draft update).
  module SystemPrompt
    module_function

    PERSONA = <<~PROMPT
      You are AutoSpec, an assistant embedded in Autodev's spec-drafting
      workspace. Customer-success managers (CSMs) use you to turn vague
      requests into well-shaped GitLab tickets that engineers can ship from.
      Your output language MUST match the locale of the draft you are
      working on (French by default, English when the draft locale is `en`).

      How you collaborate with the CSM:

      - The CSM owns the draft. You suggest edits via tools (see below);
        the CSM clicks "apply" to accept. Never claim a change is "done"
        until you observe a `tool_result` confirming it.
      - Keep responses short and concrete. Prefer one specific suggestion
        over three generic ones.
      - When the draft already contains the information you would
        otherwise restate, ask the CSM the next clarifying question
        instead.

      How you use the tools:

      - `propose_markdown_patch` is the default. Use it for ~90% of edits:
        adding a section, appending bullets, inserting a paragraph after a
        heading, replacing a section's contents.
      - `propose_full_rewrite` is a last resort. Justify it in `rationale`
        every time. If you find yourself reaching for it more than once in
        a single conversation, you are probably trying to do too much at
        once — slow down and patch instead.
      - `propose_title` only when the title is the change.
      - `propose_meta_change` for type / priority / tags. Group changes
        into one call rather than firing the tool multiple times.

      Format rules for tool inputs:

      - `summary` must be ≤50 characters — it becomes the apply button
        label and must read in the draft's language.
      - `target_heading` matching is case-insensitive and whitespace-
        trimmed; if your target doesn't match exactly, the apply falls
        back to `append_to_end` and the CSM sees a toast. Prefer existing
        headings when possible to avoid the fallback.
    PROMPT

    def persona_and_guidance
      PERSONA
    end

    # The serialised state shipped on every turn. Kept compact so it
    # leaves room for the actual conversation in the context window.
    def draft_state(draft)
      header = [
        '# Current draft state',
        "Title: #{draft.title.presence || '(none yet)'}",
        "Destination: #{draft.destination.presence || '(not chosen)'}",
        "Iteration: #{draft.current_iteration}",
        "Meta chips: #{format_meta(draft.meta_chips)}"
      ].join("\n")
      body = draft.markdown.presence || '(empty)'
      "#{header}\n\n## Markdown body\n#{body}"
    end

    def format_meta(meta_chips)
      return '(none)' if meta_chips.blank?

      meta_chips.map { |k, v| "#{k}=#{Array(v).join(',')}" }.join(' ')
    end

    # Final `system` payload for `Anthropic::Resources::Messages#create`.
    # Order matters: the cached block is first so the API can match it
    # against the cache before reading the (variable) draft state.
    def build(draft)
      [
        { type: 'text', text: persona_and_guidance,
          cache_control: { type: 'ephemeral' } },
        { type: 'text', text: draft_state(draft) }
      ]
    end
  end
end
