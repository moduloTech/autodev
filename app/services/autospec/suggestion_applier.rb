# frozen_string_literal: true

module Autospec
  # Applies one suggestion (a `tool_use` block emitted by Claude in an
  # AutospecMessage) to the matching AutospecDraft, then stamps
  # `applied_at` on the persisted tool_call so the next chat turn's
  # synthetic `tool_result` (cf. autodev/docs/autospec.md §G "Tool
  # results synthétiques") reports the application back to the model.
  #
  # Idempotent: re-applying a tool_call whose `applied_at` is already
  # set raises `AlreadyApplied` rather than re-running the patch (which
  # would otherwise double-append, double-rewrite, etc.). The caller
  # surfaces that as a 409.
  #
  # Tool dispatch (cf. autospec.md §G):
  #
  #   - `propose_markdown_patch` → MarkdownPatcher, may fall back to
  #     append_to_end and set `fell_back?` on the Result.
  #   - `propose_full_rewrite`   → replaces `markdown` wholesale.
  #   - `propose_title`          → updates `title`.
  #   - `propose_meta_change`    → merges into `meta_chips` (only the
  #     keys present in the input are touched).
  class SuggestionApplier
    class AlreadyApplied < StandardError; end
    class ToolUseNotFound < StandardError; end
    class UnsupportedTool < StandardError; end

    META_KEYS = %w[type priority tags].freeze

    HANDLERS = {
      'propose_markdown_patch' => :apply_patch!,
      'propose_full_rewrite' => :apply_full_rewrite!,
      'propose_title' => :apply_title!,
      'propose_meta_change' => :apply_meta!
    }.freeze

    Result = Struct.new(:draft, :tool_call, :fell_back?)

    def initialize(message, tool_use_id)
      @message     = message
      @tool_use_id = tool_use_id
      @fell_back   = false
    end

    def call
      tool_call = locate_tool_call!
      raise AlreadyApplied, "tool_use #{@tool_use_id.inspect} already applied" if tool_call['applied_at']

      dispatch_to_handler!(@message.autospec_draft, tool_call)
      stamp_applied!(tool_call)

      Result.new(draft: @message.autospec_draft.reload, tool_call: tool_call, fell_back?: @fell_back)
    end

    private

    def locate_tool_call!
      tool_call = Array(@message.tool_calls).find { |c| c['id'] == @tool_use_id }
      raise ToolUseNotFound, "tool_use #{@tool_use_id.inspect} not in message ##{@message.id}" unless tool_call

      tool_call
    end

    def dispatch_to_handler!(draft, tool_call)
      handler = HANDLERS[tool_call['name']]
      raise UnsupportedTool, tool_call['name'].inspect unless handler

      send(handler, draft, tool_call['input'] || {})
    end

    def apply_patch!(draft, input)
      result = MarkdownPatcher.new(draft.markdown).apply(
        operation: input['operation'], content: input['content'],
        target_heading: input['target_heading']
      )
      draft.update!(markdown: result.markdown)
      @fell_back = result.fell_back?
    end

    def apply_full_rewrite!(draft, input)
      draft.update!(markdown: input['content'])
    end

    def apply_title!(draft, input)
      draft.update!(title: input['title'])
    end

    def apply_meta!(draft, input)
      chips = (draft.meta_chips || {}).dup
      META_KEYS.each { |k| chips[k] = input[k] if input.key?(k) }
      draft.update!(meta_chips: chips)
    end

    def stamp_applied!(tool_call)
      tool_call['applied_at'] = Time.current.iso8601
      # The :json AR attribute does shallow change-detection on object
      # identity; mutating an element inside the array doesn't dirty the
      # column. `tool_calls_will_change!` tells AR to persist anyway.
      @message.tool_calls_will_change!
      @message.save!
    end
  end
end
