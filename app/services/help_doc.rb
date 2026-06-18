# frozen_string_literal: true

require 'redcarpet'

# Renders one of the in-app help docs as HTML. The markdown sources are
# shared with the markdown-friendly tools the operator uses on disk
# (GitHub render, `md2pdf` historically), so they carry pandoc-only
# artifacts that need stripping before web rendering:
#
#   - YAML frontmatter (`--- … ---`) — pandoc config, not content.
#   - `\newpage` lines — LaTeX page breaks for the printed PDF.
#   - Relative image refs (`screenshots/01-dashboard.png`) — must be
#     rewritten to a web-served URL.
#
# Two kinds are supported:
#
#   - `:functional` — `docs/usage/autodev-functional-usage.md`, served at
#     `/help` to every signed-in user.
#   - `:technical` — `docs/usage/autodev-technical-usage.md`, served at
#     `/admin/help`, admin-gated.
class HelpDoc
  SOURCES = {
    functional: Rails.root.join('docs/usage/autodev-functional-usage.md'),
    technical: Rails.root.join('docs/usage/autodev-technical-usage.md')
  }.freeze

  SCREENSHOT_DIR = Rails.root.join('docs/usage/screenshots')

  # Restricts what HelpController#image will serve from SCREENSHOT_DIR.
  # Anything not matching this is treated as a 404.
  ALLOWED_IMAGE_NAME = /\A[\w-]+\.png\z/

  # Project-aware label tokens embedded in the functional guide:
  #   {{label_todo|à traiter}}  {{label_doing|en cours}}  {{label_done|livré}}
  # The web render swaps each token for the project's configured label name
  # (passed via `labels:`); when no value is supplied the inline default
  # (after `|`) is used — that default also keeps the raw markdown readable
  # on disk / GitHub. Only the functional doc carries these tokens; the
  # technical doc renders verbatim.
  LABEL_TOKEN = /\{\{(label_todo|label_doing|label_done)\|([^}]*)\}\}/

  def self.render(kind, labels: {})
    new(kind, labels: labels).render
  end

  def initialize(kind, labels: {})
    @kind = kind.to_sym
    @labels = labels || {}
    @source_path = SOURCES.fetch(@kind) { raise ArgumentError, "unknown help kind: #{kind.inspect}" }
  end

  def render
    markdown = strip_pandoc_only(File.read(@source_path))
    markdown = rewrite_image_paths(markdown)
    markdown = substitute_labels(markdown)
    renderer.render(markdown).html_safe
  end

  private

  # Replace each `{{key|default}}` token with the configured label value,
  # falling back to the inline default when the value is blank or absent.
  def substitute_labels(text)
    text.gsub(LABEL_TOKEN) do
      key = ::Regexp.last_match(1)
      default = ::Regexp.last_match(2)
      value = @labels[key].to_s.strip
      value.empty? ? default : value
    end
  end

  # `---\n…\n---\n` block at the top of the file (pandoc YAML frontmatter)
  # plus any `\newpage` line scattered through.
  def strip_pandoc_only(text)
    text = text.sub(/\A---\n.*?\n---\n+/m, '')
    text.gsub(/^\\newpage\s*$\n*/m, '')
  end

  # The markdown references `screenshots/<file>.png` (relative to
  # `docs/usage/`). The web app serves them under `/help/images/<file>`,
  # the same endpoint for both functional and technical docs.
  def rewrite_image_paths(text)
    text.gsub(%r{!\[([^\]]*)\]\(screenshots/([^)]+)\)}) do
      "![#{::Regexp.last_match(1)}](/help/images/#{::Regexp.last_match(2)})"
    end
  end

  def renderer
    @renderer ||= Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(escape_html: false, hard_wrap: false),
      tables: true,
      fenced_code_blocks: true,
      autolink: true,
      strikethrough: true,
      no_intra_emphasis: true,
      space_after_headers: true
    )
  end
end
