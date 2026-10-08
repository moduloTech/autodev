# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/issue_processor'

# Autodev #122. The spec check's prompt carried one rule about blocking, and it
# pushed towards *not* blocking. The three criteria below are what made
# POWERPANNE#14746 come out "unclear" in the corpus evaluation recorded in the
# design doc; deleting one of them is a product decision, not a rewording, so
# each is pinned by the words that carry it.
class SpecCheckPromptTest < Minitest::Test
  PROMPT = IssueProcessor::Prompts::SPEC_CHECK

  def test_a_description_contradicted_by_a_later_answer_blocks
    assert_match(/La description contredit une reponse donnee plus tard dans les commentaires/, PROMPT)
  end

  def test_an_undescribed_decision_blocks_and_names_what_must_be_described
    assert_match(/Une decision est prise, mais ce qu'elle implique n'est pas decrit/, PROMPT)
    %w[ecran acces sortie remplace].each { |word| assert_includes PROMPT, word }
  end

  def test_an_answer_that_changes_the_nature_of_the_request_needs_its_implications
    assert_match(/change la nature de la demande/, PROMPT)
    assert_match(/Ne conclus alors\s+`"implementation"` que si/, PROMPT)
  end

  def test_pragmatism_survives_for_truly_minor_details
    assert_match(/details vraiment mineurs/, PROMPT)
  end

  def test_the_answer_shape_parse_spec_result_reads_is_unchanged
    assert_includes PROMPT, '"type": "implementation" | "question" | "unclear"'
    assert_includes PROMPT, '"issues"'
  end

  # `format(SPEC_CHECK, path)` is how the check fills it: exactly one
  # placeholder and no stray `%` for `format` to choke on.
  def test_it_formats_with_the_context_path_alone
    assert_includes format(PROMPT, '/tmp/ctx.md'), '`/tmp/ctx.md`'
  end
end
