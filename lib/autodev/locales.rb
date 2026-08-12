# frozen_string_literal: true

require 'i18n'
require 'i18n/backend/fallbacks'

# Locale-aware message templates for GitLab issue comments, activity log
# entries, the embedded web UI and the CLI's boot diagnostics.
#
# Step 7 of the railsification (cf. autodev/docs/autospec.md §C item 7)
# moved the source of truth from three Ruby hashes (NOTIFICATION_TEMPLATES,
# ACTIVITY_TEMPLATES, WEB_TEMPLATES) to three thematic YAML files under
# `config/locales/*.{fr,en}.yml`. The Ruby `Locales.t(key, locale:, **vars)`
# API is preserved — every caller (~140 of them between `lib/autodev/*` and
# `app/controllers/*`) continues to work unchanged.
#
# Backend setup:
#   - `Locales::LOCALE_FILES_GLOB` enumerates the YAMLs.
#   - I18n.load_path is extended with that glob (idempotent — guarded so
#     re-requiring this file in dev hot-reload doesn't pile entries up).
#   - I18n::Backend::Fallbacks is included so any locale silently falls
#     back to :fr when a key is missing.
#   - `available_locales = [:fr, :en]`, `default_locale = :fr`.
#
# Rails auto-loads `config/locales/**/*.yml` via its own railtie — but it
# does so AFTER the application has initialized, while `bin/autodev`'s
# pure-Sinatra entry point requires `lib/autodev` very early. Loading the
# files here covers both code paths and is idempotent (Rails appending the
# same glob a second time is a no-op).
module Locales
  LOCALE_FILES_GLOB = File.expand_path('../../config/locales/{notifications,activity,web,cli}.*.yml', __dir__)

  # Eagerly extend I18n's load path + fallbacks the first time the module
  # is required. Idempotent: the glob is the same every time, and the
  # Fallbacks module short-circuits on re-inclusion.
  unless instance_variable_defined?(:@configured)
    I18n.load_path |= Dir[LOCALE_FILES_GLOB]
    unless I18n::Backend::Simple.include?(I18n::Backend::Fallbacks)
      I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
    end
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:fr)
    I18n.available_locales |= %i[fr en]
    I18n.default_locale = :fr unless I18n.default_locale
    @configured = true
  end

  # Public API. `locale:` is mandatory at this layer (callers pick from
  # `issue.locale`, a config field, or default to :fr at the call site).
  # On missing key returns `key.to_s` so unmapped keys surface visibly
  # in GitLab notes / activity logs rather than as "translation missing".
  # Unknown locales (e.g. an `issue.locale` that drifted to ":de") fall
  # back to French rather than raising `I18n::InvalidLocale`.
  def self.t(key, locale: :fr, **vars)
    locale = :fr unless I18n.available_locales.include?(locale.to_sym)
    I18n.t(key, locale: locale, default: key.to_s, **vars).to_s
  end

  # Low-level lookup: returns the raw template string (no interpolation,
  # no fallback) for a key in a specific locale, or `nil` if the key is
  # absent. Used by `Web::I18nHelpers#event_label` which wants to detect
  # the "no translation registered" case and substitute the bare event
  # symbol rather than emitting the key string itself.
  def self.lookup(locale, key)
    locale = :fr unless I18n.available_locales.include?(locale.to_sym)
    val = I18n.t(key, locale: locale, default: nil, raise: false)
    val.is_a?(String) ? val : nil
  end

  # Flat hash of every key available for the given locale across our
  # thematic YAML tables. Used by test parity checks (every FR key has an
  # EN counterpart and vice versa). Walks the YAML files directly rather
  # than the I18n backend — when the Rails railtie loads `rails-i18n` /
  # ActiveSupport's built-in `date` / `time` / `support` / `number`
  # namespaces into the same backend, those would otherwise bleed into
  # the parity check and make it noisy. Not on the request path.
  def self.merged_for(locale)
    locale_str = locale.to_s
    Dir[LOCALE_FILES_GLOB].each_with_object({}) do |path, acc|
      content = YAML.safe_load_file(path)
      next unless content.is_a?(Hash) && content[locale_str].is_a?(Hash)

      content[locale_str].each { |k, v| acc[k.to_sym] = v }
    end
  end
end
