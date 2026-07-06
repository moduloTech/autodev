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

    # Localized human-readable label for an AASM status. Reads from the
    # canonical mapping in Web::Views::Components::StatusPill::STATUS_DATA.
    def status_label(status)
      data = Web::Views::Components::StatusPill::STATUS_DATA[status.to_s]
      return status.to_s unless data

      t_web(data[:label_key])
    end

    # Effective display status for an issue row: a `done` issue flagged
    # needs_attention renders as the synthetic `done_attention` status (warn
    # pill), so a "gave-up done" is visually distinct from a clean delivery.
    # Reads needs_attention defensively so it works for AR rows and hashes alike.
    def issue_status(row)
      status = row[:status].to_s
      return 'done_attention' if status == 'done' && row[:needs_attention]

      status
    end

    # Build a StatusPill component ready for `render`. Resolves the
    # localized label here so the component itself stays presentation-only.
    def status_pill(status, size: :md, with_dot: true)
      Web::Views::Components::StatusPill.new(
        status: status, label: status_label(status), size: size, with_dot: with_dot
      )
    end

    # Localized human-readable label for an AASM event (transition trigger).
    # Falls back to the raw symbol/string if no translation is registered.
    def event_label(event)
      key = :"web_event_#{event}"
      Locales.lookup(web_locale, key) || Locales.lookup(:fr, key) || event.to_s
    end

    # Localized "il y a 4 min" / "4 min ago" relative-time helper.
    # Falls back to the raw timestamp if parsing fails.
    def relative_time(timestamp) # rubocop:disable Metrics/AbcSize
      return '' if timestamp.nil? || timestamp.to_s.empty?

      diff = Time.now - Time.parse(timestamp.to_s)
      return t_web(:web_time_just_now)               if diff < 60
      return t_web(:web_time_minutes_ago, n: (diff / 60).to_i) if diff < 3600
      return t_web(:web_time_hours_ago,   n: (diff / 3600).to_i) if diff < 86_400

      t_web(:web_time_days_ago, n: (diff / 86_400).to_i)
    rescue ArgumentError
      timestamp.to_s
    end

    # Human label for a ticket's author (task #27). Prefers the GitLab display
    # name captured at ingest; falls back to the numeric author id for rows
    # created before the name column existed, then an em-dash when neither is
    # known. Reads defensively so it works for AR rows and plain hashes alike.
    def author_display(row)
      name = row[:issue_author_name].to_s.strip
      return name unless name.empty?
      return "##{row[:issue_author_id]}" if row[:issue_author_id]

      '—'
    end

    # Two-letter monogram for the avatar bubble: initials of the first two
    # words of a display name ("Jean Dupont" → "JD"), or the first two
    # characters of anything else (an id fallback like "#42" → "#4").
    def author_initials(display)
      words = display.to_s.split(/\s+/).reject(&:empty?)
      return (words[0][0].to_s + words[1][0].to_s).upcase if words.size >= 2

      display.to_s[0, 2].upcase
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
