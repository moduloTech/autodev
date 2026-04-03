# frozen_string_literal: true

require_relative 'test_helper'

class LanguageDetectorTest < Minitest::Test
  def test_nil_returns_french
    assert_equal :fr, LanguageDetector.detect(nil)
  end

  def test_empty_string_returns_french
    assert_equal :fr, LanguageDetector.detect('')
  end

  def test_whitespace_only_returns_french
    assert_equal :fr, LanguageDetector.detect("   \n  ")
  end

  def test_french_text
    assert_equal :fr, LanguageDetector.detect(
      'Le projet est dans les fichiers du serveur. Il faut corriger une erreur dans la configuration.'
    )
  end

  def test_english_text
    assert_equal :en, LanguageDetector.detect(
      'The project is in the server files. We need to fix a bug in the configuration.'
    )
  end

  def test_mixed_french_dominant
    assert_equal :fr, LanguageDetector.detect(
      'Le module user est cassé. The API returns 500 pour les requêtes avec un token invalide.'
    )
  end

  def test_mixed_english_dominant
    assert_equal :en, LanguageDetector.detect(
      'The user module is broken and the API returns errors for all requests in the system.'
    )
  end

  def test_equal_counts_defaults_to_french
    # "est" is FR, "is" is EN — one of each
    assert_equal :fr, LanguageDetector.detect('est is')
  end

  def test_punctuation_stripped
    assert_equal :en, LanguageDetector.detect(
      'The project, which is broken, needs to be fixed. This is a priority.'
    )
  end

  def test_case_insensitive
    assert_equal :en, LanguageDetector.detect('THE PROJECT IS IN THE FILES')
  end
end
