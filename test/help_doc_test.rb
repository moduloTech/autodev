# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Coverage for HelpDoc's project-aware label substitution. Renders the real
# functional guide, so it also guards that the `{{label_*|default}}` tokens
# stay present in the source.
class HelpDocTest < Minitest::Test
  def test_tokens_are_replaced_by_configured_labels
    html = HelpDoc.render(:functional, labels: {
                            'label_todo' => 'To Do', 'label_doing' => 'Doing', 'label_done' => 'Done'
                          })

    assert_includes html, 'To Do'
    refute_includes html, 'à traiter', 'the inline default must be overridden'
    refute_includes html, '{{', 'no token must survive rendering'
  end

  def test_blank_labels_fall_back_to_inline_defaults
    html = HelpDoc.render(:functional, labels: {})

    assert_includes html, 'à traiter', 'falls back to the inline default'
    refute_includes html, '{{', 'no token must survive rendering'
  end

  def test_partial_labels_mix_value_and_default
    html = HelpDoc.render(:functional, labels: { 'label_todo' => 'To Do' })

    assert_includes html, 'To Do'
    assert_includes html, 'en cours', 'label_doing keeps its default'
    refute_includes html, '{{'
  end

  # The technical doc carries no tokens — it must render verbatim.
  def test_technical_doc_is_unaffected
    refute_includes HelpDoc.render(:technical, labels: { 'label_todo' => 'To Do' }), '{{'
  end
end
