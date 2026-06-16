# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class MarkdownRendererTest < ActiveSupport::TestCase
    def test_blank_input_returns_empty_string
      assert_equal '', MarkdownRenderer.render('')
      assert_equal '', MarkdownRenderer.render(nil)
    end

    def test_renders_headings
      html = MarkdownRenderer.render("## Steps\n\nbody")

      assert_includes html, '<h2>Steps</h2>'
      assert_includes html, '<p>body</p>'
    end

    def test_renders_inline_emphasis_and_code
      html = MarkdownRenderer.render('A **bold** and `code` line.')

      assert_includes html, '<strong>bold</strong>'
      assert_includes html, '<code>code</code>'
    end

    def test_renders_lists_and_blockquote
      html = MarkdownRenderer.render("- one\n- two\n\n> quoted")

      assert_includes html, '<ul>'
      assert_includes html, '<li>one</li>'
      assert_includes html, '<blockquote>'
    end

    # User content — anything resembling raw HTML must be escaped, not
    # passed through. Mirrors the security posture documented in the
    # renderer (escape_html: true).
    def test_escapes_raw_html_in_user_content
      html = MarkdownRenderer.render('<script>alert(1)</script>')

      refute_includes html, '<script>'
      assert_includes html, '&lt;script&gt;'
    end

    def test_no_intra_emphasis_keeps_snake_case_identifiers_intact
      html = MarkdownRenderer.render('use my_variable_name here')

      refute_includes html, '<em>'
    end
  end
end
