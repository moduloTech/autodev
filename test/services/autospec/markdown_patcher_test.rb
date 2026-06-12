# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class MarkdownPatcherTest < ActiveSupport::TestCase
    def test_append_to_end_on_empty_markdown
      result = MarkdownPatcher.new('').apply(operation: 'append_to_end', content: 'hello')

      assert_equal "hello\n", result.markdown
      refute_predicate result, :fell_back?
    end

    def test_append_to_end_appends_with_blank_line
      result = MarkdownPatcher.new("# Existing\n\nbody").apply(
        operation: 'append_to_end', content: '- new bullet'
      )

      assert_equal "# Existing\n\nbody\n\n- new bullet\n", result.markdown
    end

    def test_create_section_appends_heading_then_body
      result = MarkdownPatcher.new('# Existing').apply(
        operation: 'create_section', target_heading: 'Cas limites',
        content: '- l\'utilisateur revient en arrière'
      )

      assert_match(/## Cas limites\n\n- l'utilisateur revient en arrière\n\z/, result.markdown)
    end

    def test_create_section_preserves_explicit_heading_level
      result = MarkdownPatcher.new('').apply(
        operation: 'create_section', target_heading: '### Sous-section',
        content: 'body'
      )

      assert_match(/### Sous-section/, result.markdown)
    end

    def test_insert_after_heading_finds_target
      input = "# Spec\n\nintro paragraph\n\n## Détails\n\nold detail\n"
      result = MarkdownPatcher.new(input).apply(
        operation: 'insert_after_heading', target_heading: 'Spec',
        content: 'inserted line'
      )

      assert_match(/# Spec\n\ninserted line\n\nintro paragraph/, result.markdown)
      refute_predicate result, :fell_back?
    end

    def test_insert_after_heading_is_case_insensitive
      input = "## Cas Limites\n\nbody\n"
      result = MarkdownPatcher.new(input).apply(
        operation: 'insert_after_heading', target_heading: 'cas limites',
        content: 'extra'
      )

      assert_match(/extra/, result.markdown)
      refute_predicate result, :fell_back?
    end

    def test_insert_after_heading_falls_back_when_missing
      input = "## Détails\n\nbody\n"
      result = MarkdownPatcher.new(input).apply(
        operation: 'insert_after_heading', target_heading: 'inexistant',
        content: 'extra'
      )

      assert_predicate result, :fell_back?
      assert_match(/extra\n\z/, result.markdown)
    end

    def test_replace_section_replaces_body_only
      input = "## A\n\nold body\n\n## B\n\nkeep me\n"
      result = MarkdownPatcher.new(input).apply(
        operation: 'replace_section', target_heading: 'A', content: 'new body'
      )

      assert_match(/## A\n\nnew body\n\n## B\n\nkeep me/, result.markdown)
    end

    def test_replace_section_stops_at_same_level_or_higher
      input = "## A\n\nold body\n\n### Subsection of A\n\nsub body\n\n## B\n\nB body\n"
      result = MarkdownPatcher.new(input).apply(
        operation: 'replace_section', target_heading: 'A', content: 'new'
      )

      assert_match(/## A\n\nnew\n\n## B/, result.markdown)
      refute_match(/Subsection of A/, result.markdown)
    end

    def test_replace_section_replaces_until_eof_when_last
      result = MarkdownPatcher.new("## Only\n\nold\n").apply(
        operation: 'replace_section', target_heading: 'Only', content: 'new'
      )

      assert_match(/## Only\n\nnew\n/, result.markdown)
    end

    def test_replace_section_falls_back_when_missing
      input = "## A\n\nbody\n"
      result = MarkdownPatcher.new(input).apply(
        operation: 'replace_section', target_heading: 'Z', content: 'new'
      )

      assert_predicate result, :fell_back?
    end

    def test_unknown_operation_raises
      assert_raises(Autospec::MarkdownPatcher::UnknownOperation) do
        Autospec::MarkdownPatcher.new('').apply(operation: 'nuke', content: 'x')
      end
    end
  end
end
