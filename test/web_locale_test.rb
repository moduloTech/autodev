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

    assert_includes last_response.body, 'Hello'
    assert_includes last_response.body, 'Active requests'
  end

  def test_french_dashboard_uses_french_nav
    Web::Server.configure_with('web' => { 'locale' => 'fr' })
    get '/'

    assert_includes last_response.body, 'Bonjour'
    assert_includes last_response.body, 'Demandes en cours'
  end

  def test_invalid_locale_falls_back_to_french
    Web::Server.configure_with('web' => { 'locale' => 'klingon' })
    get '/'

    assert_includes last_response.body, 'Bonjour'
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

  def test_locale_switcher_route_sets_cookie_and_redirects
    Web::Server.configure_with('web' => { 'locale' => 'fr' })
    get '/locale/en'

    assert_equal 302, last_response.status
    assert_match(/locale=en/, last_response.headers['set-cookie'].to_s)
  end

  def test_cookie_overrides_config_locale
    Web::Server.configure_with('web' => { 'locale' => 'fr' })
    set_cookie 'locale=en'
    get '/'

    assert_includes last_response.body, 'Hello'
  end

  def test_invalid_locale_in_cookie_falls_back_to_config
    Web::Server.configure_with('web' => { 'locale' => 'fr' })
    set_cookie 'locale=klingon'
    get '/'

    assert_includes last_response.body, 'Bonjour'
  end

  def test_locale_switcher_rejects_unknown_lang_and_clears_cookie
    Web::Server.configure_with({})
    set_cookie 'locale=en'
    get '/locale/klingon'

    assert_equal 302, last_response.status
  end

  def test_locale_switcher_redirect_back_only_accepts_local_paths
    Web::Server.configure_with({})
    get '/locale/en?back=https://evil.example.com/x'
    location = URI(last_response.headers['location']).path

    assert_equal '/', location
  end

  def test_locale_switcher_preserves_local_back_param
    Web::Server.configure_with({})
    get '/locale/en?back=/issues'
    location = URI(last_response.headers['location']).path

    assert_equal '/issues', location
  end

  def test_nav_renders_language_switcher
    Web::Server.configure_with({})
    get '/'

    assert_includes last_response.body, '/locale/en'
    assert_includes last_response.body, '<strong>FR</strong>'
  end
end
