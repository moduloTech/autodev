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

  # Every ToC anchor must point at a heading id that actually exists in the
  # body — the reason the ToC is built from the rendered body rather than
  # Redcarpet's HTML_TOC (which disagrees on apostrophes/accents).
  def test_toc_anchors_all_resolve_to_body_headings
    body = HelpDoc.render(:functional)
    hrefs = HelpDoc.toc(:functional).scan(/href="#([^"]+)"/).flatten
    ids = body.scan(/id="([^"]+)"/).flatten

    refute_empty hrefs, 'the functional doc should yield a non-empty ToC'
    assert_empty (hrefs - ids), 'ToC anchors with no matching heading id'
  end

  def test_toc_is_built_for_the_technical_doc
    toc = HelpDoc.toc(:technical)

    assert_includes toc, '<ul'
    assert_match(/href="#/, toc)
  end
end
