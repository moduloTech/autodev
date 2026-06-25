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
  module SystemPrompt # rubocop:disable Metrics/ModuleLength
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

    # The project's ticket template(s) (task #14 + follow-up) — the structure
    # the CSM's org expects, so they no longer copy-paste a template into the
    # chat. Three branches, each returning one block:
    #   1. the draft has a chosen template → follow + verify against it;
    #   2. no choice but the project defines templates → propose the best-fit;
    #   3. the project defines none → a generic default structure (draft locale).
    def ticket_templates(draft)
      return chosen_template_block(draft) if draft.ticket_template

      templates = draft.project ? draft.project.ticket_templates.to_a : []
      return default_template_block(draft) if templates.empty?

      propose_template_block(templates)
    end

    # Task #14 follow-up — the CSM explicitly picked a template: AutoSpec
    # follows it AND, when assessing quality, verifies the ticket against it
    # (lists missing / empty / extra sections vs the template).
    def chosen_template_block(draft)
      tpl = draft.ticket_template
      <<~TXT.chomp
        # Ticket template (chosen by the CSM)

        The CSM chose the "#{tpl.name}" template for this ticket. Structure the
        ticket to follow its sections (translate the headings into the draft's
        language). Whenever you assess the ticket's quality, explicitly verify
        it against this template: list any of the template's sections that are
        missing or left empty, and any extra sections that don't belong. Do not
        drop or rename the template's sections unless the CSM asks.

        ## #{tpl.name}
        #{tpl.body}
      TXT
    end

    # Task #14 follow-up — no template chosen but the project defines some:
    # AutoSpec proposes the best-fit one and offers to format the ticket.
    def propose_template_block(templates)
      intro = <<~TXT.chomp
        # Ticket templates for this project

        The CSM has NOT chosen a template. Based on the request, proactively
        propose the most appropriate template among those below, say which one
        and why, and offer to restructure the ticket to match it. If it's
        genuinely ambiguous, ask the CSM which kind it is. Don't invent sections
        a template doesn't have.
      TXT
      ([intro] + templates.map { |t| "## #{t.name}\n#{t.body}" }).join("\n\n")
    end

    def default_template_block(draft)
      <<~TXT.chomp
        # Default ticket structure

        This project hasn't defined custom templates. Structure the ticket
        using these default sections (translate the headings into the draft's
        language):

        #{Locales.t(:web_autospec_default_template_body, locale: template_locale(draft))}
      TXT
    end

    def template_locale(draft)
      (draft.project&.default_locale.presence || 'fr').to_sym
    end

    # Final `system` payload for `Anthropic::Resources::Messages#create`.
    # Order matters: the cached blocks come first so the API can match
    # them against the cache before reading the (variable) draft state.
    # The ticket-templates block sits after the cached prefix (it changes
    # when an admin edits templates) and before the per-turn draft state.
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
      blocks << { type: 'text', text: ticket_templates(draft) }
      blocks << { type: 'text', text: draft_state(draft) }
      blocks
    end
  end
end
