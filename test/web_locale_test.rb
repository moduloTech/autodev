# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'

class WebLocaleTest < Minitest::Test
  include Rack::Test::Methods
  include DatabaseTestHelper

  def app
    Web::Server
  end

  def setup
    setup_database
  end

  def test_default_locale_is_french
    Web::Server.configure_with({})
    get '/errors'

    assert_includes last_response.body, 'Erreurs'
    refute_includes last_response.body, 'Errors'
  end

  def test_english_locale_renders_english_strings
    Web::Server.configure_with('web' => { 'enabled' => true, 'port' => 4567, 'locale' => 'en' })
    get '/errors'

    assert_includes last_response.body, 'Errors'
  end

  def test_english_dashboard_uses_english_nav
    Web::Server.configure_with('web' => { 'locale' => 'en' })
    get '/'

    assert_includes last_response.body, 'All issues'
    assert_includes last_response.body, 'By project'
  end

  def test_french_dashboard_uses_french_nav
    Web::Server.configure_with('web' => { 'locale' => 'fr' })
    get '/'

    assert_includes last_response.body, 'Toutes les issues'
    assert_includes last_response.body, 'Par projet'
  end

  def test_invalid_locale_falls_back_to_french
    Web::Server.configure_with('web' => { 'locale' => 'klingon' })
    get '/'

    assert_includes last_response.body, 'Toutes les issues'
  end

  def test_locale_validator_rejects_unknown
    config = { 'gitlab_token' => 'glpat-x', 'poll_interval' => 1, 'max_workers' => 1, 'dc_timeout' => 1,
               'max_retries' => 1, 'retry_backoff' => 1, 'pickup_delay' => 1, 'stagnation_threshold' => 1,
               'log_level' => 'INFO', 'web' => { 'enabled' => true, 'port' => 4567, 'locale' => 'klingon' } }

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end

  def test_locale_validator_accepts_fr_and_en
    base = { 'gitlab_token' => 'glpat-x', 'poll_interval' => 1, 'max_workers' => 1, 'dc_timeout' => 1,
             'max_retries' => 1, 'retry_backoff' => 1, 'pickup_delay' => 1, 'stagnation_threshold' => 1,
             'log_level' => 'INFO' }

    %w[fr en].each do |loc|
      ConfigValidator.validate_globals!(base.merge('web' => { 'enabled' => true, 'port' => 4567, 'locale' => loc }))
    end
  end
end
