# frozen_string_literal: true

module Web
  # Locale resolution and string lookup for view templates.
  # Resolution order: cookie > config (`web.locale`) > default ('fr').
  module I18nHelpers
    DEFAULT_LOCALE = :fr
    AVAILABLE_LOCALES = %w[fr en].freeze

    def web_locale
      cookie = cookie_locale
      return cookie.to_sym if cookie

      (app_config.dig('web', 'locale') || DEFAULT_LOCALE).to_sym
    end

    def cookie_locale
      raw = request.cookies['locale'] if respond_to?(:request) && request
      raw if AVAILABLE_LOCALES.include?(raw)
    end

    # Lookup a web string in the configured locale, fallback to FR.
    def t_web(key, **vars)
      Locales.t(key, locale: web_locale, **vars)
    end

    STATUS_LABEL_KEYS = { 'pending' => :web_status_pending, 'done' => :web_status_done,
                          'error' => :web_status_error,
                          'needs_clarification' => :web_status_needs_clarification }.freeze

    # Localized human-readable label for an AASM status.
    def status_label(status)
      key = STATUS_LABEL_KEYS[status] || (Dashboard::ACTIVE_STATES.include?(status) ? :web_status_active : nil)
      key ? t_web(key) : status.to_s
    end

    # Set or clear the locale cookie based on `lang`. Used by /locale/:lang.
    def apply_locale_cookie!(lang)
      if AVAILABLE_LOCALES.include?(lang)
        response.set_cookie('locale', value: lang, path: '/', max_age: 31_536_000)
      else
        response.delete_cookie('locale', path: '/')
      end
    end

    # Sanitize a `back` redirect target so it can't escape the host.
    def safe_back_path(raw)
      raw.to_s.start_with?('/') ? raw : '/'
    end
  end
end
