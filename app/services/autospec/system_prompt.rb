# frozen_string_literal: true

module Autospec
  # Builds the `system` parameter for an Anthropic Messages API call.
  #
  # Up to three blocks:
  #
  #   1. persona + tool-usage guidance — stable across the entire session,
  #      tagged `cache_control: { type: 'ephemeral' }` so Anthropic caches
  #      it for the 5-minute TTL and subsequent turns in the same chat
  #      hit the cache.
  #   2. project briefing (OPTIONAL) — refreshed hourly by
  #      `RefreshProjectBriefingsJob` from the `staging` branch via
  #      `Autospec::ProjectBriefer`. Stored on `Project.briefing_text`;
  #      omitted when nil (e.g. fresh project, danger-claude unavailable,
  #      tests). Also `cache_control: ephemeral` — Anthropic's cache lets
  #      us stack two breakpoints, and the briefing changes at most once
  #      an hour so cache hits are the common case across draft turns.
  #   3. draft state (title + markdown + meta_chips) — changes whenever
  #      the CSM edits, so we don't cache it.
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

    # The project briefing (when present) tells Claude WHAT the project
    # is — its domain, conventions, lexicon. Refreshed hourly so the
    # chat path is read-only, no clone/danger-claude latency at message
    # time.
    def project_briefing(project)
      return nil if project.nil? || project.briefing_text.blank?

      [
        '# Project briefing',
        "_Generated at #{project.briefing_generated_at&.iso8601 || 'unknown'}._",
        '',
        project.briefing_text
      ].join("\n")
    end

    # Final `system` payload for `Anthropic::Resources::Messages#create`.
    # Order matters: the cached blocks come first so the API can match
    # them against the cache before reading the (variable) draft state.
    def build(draft) # rubocop:disable Metrics/MethodLength
      blocks = [
        { type: 'text', text: persona_and_guidance,
          cache_control: { type: 'ephemeral' } }
      ]
      briefing = project_briefing(draft.project)
      if briefing
        blocks << { type: 'text', text: briefing,
                    cache_control: { type: 'ephemeral' } }
      end
      blocks << { type: 'text', text: draft_state(draft) }
      blocks
    end
  end
end
