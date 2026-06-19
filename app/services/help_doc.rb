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

  # h1/h2 headings (with their `with_toc_data` id) in the rendered body —
  # the source the ToC is built from.
  HEADING = %r{<h([12])\s+id="([^"]+)"[^>]*>(.*?)</h\1>}m

  def self.render(kind, labels: {})
    new(kind, labels: labels).render
  end

  # Standalone table of contents (nested <ul> of anchor links) for the doc.
  # Anchors match the heading ids emitted by `render` (both go through
  # Redcarpet's shared anchor algorithm, so the links resolve).
  def self.toc(kind, labels: {})
    new(kind, labels: labels).toc
  end

  def initialize(kind, labels: {})
    @kind = kind.to_sym
    @labels = labels || {}
    @source_path = SOURCES.fetch(@kind) { raise ArgumentError, "unknown help kind: #{kind.inspect}" }
  end

  def render
    renderer.render(processed_markdown).html_safe
  end

  # Builds the ToC from the *rendered body* rather than Redcarpet's
  # HTML_TOC renderer: the two use slightly different anchor algorithms for
  # apostrophes/accents (e.g. "s'adresse" → `s-adresse` vs `sadresse`), so
  # HTML_TOC links wouldn't resolve against the body's heading ids. Reusing
  # the body's own ids guarantees every link has a target. h1 + h2 only
  # (matches the docs' `toc-depth: 2`), h2 indented under its section.
  def toc
    build_toc(render).html_safe
  end

  private

  def build_toc(body_html)
    items = body_html.scan(HEADING)
    return ''.html_safe if items.empty?

    rows = items.map do |level, id, inner|
      indent = level == '2' ? ' style="margin-left: 18px;"' : ''
      %(<li#{indent}><a href="##{id}">#{strip_tags(inner)}</a></li>)
    end
    %(<ul class="help-toc-list" style="list-style: none; padding: 0; margin: 0;">#{rows.join}</ul>)
  end

  def strip_tags(html)
    html.gsub(/<[^>]+>/, '').strip
  end

  # Frontmatter/newpage stripped, image paths rewritten, label tokens
  # substituted — the single source the body + ToC renderers both consume.
  def processed_markdown
    @processed_markdown ||=
      substitute_labels(rewrite_image_paths(strip_pandoc_only(File.read(@source_path))))
  end

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
    # `with_toc_data: true` stamps `id="…"` on every heading so the ToC's
    # anchor links have a target to jump to.
    @renderer ||= Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(escape_html: false, hard_wrap: false, with_toc_data: true),
      tables: true,
      fenced_code_blocks: true,
      autolink: true,
      strikethrough: true,
      no_intra_emphasis: true,
      space_after_headers: true
    )
  end
end
