# frozen_string_literal: true

require 'redcarpet'

module Autospec
  # Renders an AutoSpec draft's markdown body to HTML for the Aperçu
  # pane of the editor (cf. docs/design/spec_update/README.md §6).
  #
  # Unlike `HelpDoc` (which renders trusted in-app docs with
  # `escape_html: false`), this content is user-supplied — the draft
  # markdown comes from the CSM's keyboard or Claude's tool_use blocks.
  # We pass `escape_html: true` so any raw `<script>` / `<iframe>` /
  # `onclick=` in the source is rendered as text rather than active
  # markup. The `safe(...)` wrapper in the Phlex view then trusts the
  # Redcarpet output (which is HTML it produced itself, not user input).
  #
  # Tables intentionally absent at MVP — the design defers them. Adding
  # them later is one flag flip on `tables: true`.
  class MarkdownRenderer
    def self.render(markdown)
      new.render(markdown)
    end

    def render(markdown)
      return '' if markdown.blank?

      renderer.render(markdown.to_s)
    end

    private

    def renderer
      @renderer ||= Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new(escape_html: true, hard_wrap: false),
        fenced_code_blocks: true,
        autolink: true,
        strikethrough: true,
        no_intra_emphasis: true,
        space_after_headers: true
      )
    end
  end
end
