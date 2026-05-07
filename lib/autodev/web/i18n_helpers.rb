# frozen_string_literal: true

module Web
  # Locale resolution and string lookup for view templates.
  # Reads `web.locale` from the loaded autodev config (default 'fr').
  module I18nHelpers
    DEFAULT_LOCALE = :fr

    def web_locale
      (app_config.dig('web', 'locale') || DEFAULT_LOCALE).to_sym
    end

    # Lookup a web string in the configured locale, fallback to FR.
    def t_web(key, **vars)
      Locales.t(key, locale: web_locale, **vars)
    end
  end
end
