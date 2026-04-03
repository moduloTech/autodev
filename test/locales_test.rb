# frozen_string_literal: true

require_relative "test_helper"

class LocalesTest < Minitest::Test
  def test_french_template_with_interpolation
    msg = Locales.t(:processing_started, locale: :fr, tag: "**autodev**")
    assert_includes msg, "**autodev**"
    assert_includes msg, "traitement en cours"
  end

  def test_english_template_with_interpolation
    msg = Locales.t(:processing_started, locale: :en, tag: "**autodev**")
    assert_includes msg, "**autodev**"
    assert_includes msg, "processing in progress"
  end

  def test_mr_created_includes_url
    msg = Locales.t(:mr_created, locale: :en, tag: "tag", mr_url: "https://example.com/mr/1")
    assert_includes msg, "https://example.com/mr/1"
  end

  def test_unknown_locale_falls_back_to_french
    msg = Locales.t(:processing_started, locale: :de, tag: "tag")
    assert_includes msg, "traitement en cours"
  end

  def test_unknown_key_returns_key_string
    msg = Locales.t(:nonexistent_key, locale: :fr)
    assert_equal "nonexistent_key", msg
  end

  def test_all_fr_keys_have_en_counterparts
    fr_keys = Locales::TEMPLATES[:fr].keys
    en_keys = Locales::TEMPLATES[:en].keys
    missing = fr_keys - en_keys
    assert_empty missing, "EN locale is missing keys: #{missing.join(", ")}"
  end

  def test_all_en_keys_have_fr_counterparts
    fr_keys = Locales::TEMPLATES[:fr].keys
    en_keys = Locales::TEMPLATES[:en].keys
    missing = en_keys - fr_keys
    assert_empty missing, "FR locale is missing keys: #{missing.join(", ")}"
  end

  def test_pipeline_fix_success_with_all_vars
    msg = Locales.t(:pipeline_fix_success, locale: :en,
                     tag: "v1", mr_url: "url", count: 3, round: 2)
    assert_includes msg, "3"
    assert_includes msg, "2"
    assert_includes msg, "url"
  end
end
