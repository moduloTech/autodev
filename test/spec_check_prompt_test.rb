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

  # The criteria lead to "unclear", each on its own — the fragments below would
  # survive a prompt that told the model the opposite.
  def test_the_criteria_sit_under_a_blocking_heading_and_each_suffices
    blocking = PROMPT[/## Ce qui bloque : reponds "unclear"\n(.*?)## Ce qui ne bloque pas/m, 1]

    refute_nil blocking
    assert_includes blocking, 'Chacun de ces cas suffit, meme si le reste du ticket est precis'
    %w[1. 2. 3.].each { |n| assert_includes blocking, "#{n} **" }
  end

  def test_a_description_contradicted_by_a_later_answer_blocks
    assert_match(/La description contredit une reponse donnee plus tard dans les commentaires/, PROMPT)
  end

  # The hole the 28/08 implementation got wrong: whether the answer replaces the
  # original request or comes on top of it. Without these words Opus 4.7 asked
  # it explicitly in 1 draw out of 5 (design doc).
  def test_replace_or_add_is_asked_of_a_contradicting_or_redefining_answer
    assert_includes PROMPT, "Demande si la\n   reponse remplace ce que decrit la description ou s'y ajoute."
    assert_match(/dit si elle remplace la demande d'origine ou s'y ajoute/, PROMPT)
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
    assert_includes PROMPT, 'Liste les problemes dans `issues`.'
  end

  # `format(SPEC_CHECK, path)` is how the check fills it: exactly one
  # placeholder and no stray `%` for `format` to choke on.
  def test_it_formats_with_the_context_path_alone
    assert_includes format(PROMPT, '/tmp/ctx.md'), '`/tmp/ctx.md`'
  end
end
