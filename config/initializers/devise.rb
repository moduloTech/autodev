# frozen_string_literal: true

# Step 3 of the railsification — Microsoft 365 / Entra ID SSO via Devise +
# omniauth-entra-id (cf. autodev/docs/autospec.md §A and §C).
#
# Minimal config: only the Devise modules wired onto User (`:omniauthable`,
# `:trackable`) need configuration here. We skip `:database_authenticatable`
# entirely — there are no passwords, only Microsoft tenant accounts — and
# therefore none of the mailer / recoverable / confirmable settings are used.
#
# Credentials come from ENV. When unset (e.g. local dev without Entra
# registration), omniauth still mounts the provider but the actual login
# flow will fail at the redirect step. That keeps `bin/rails server` from
# 500ing at boot just because credentials are missing.
#
# To register the app in the Azure portal and obtain credentials, see
# https://github.com/RIPAGlobal/omniauth-entra-id#entra-id-server-configuration
#
# We require gems explicitly because `config/application.rb` skips
# `Bundler.require(*Rails.groups)` to keep Sinatra/Sequel out of the Rails
# process — which also means devise / omniauth aren't auto-required by
# bundler at boot.

require 'devise'
require 'omniauth-entra-id'
require 'omniauth/rails_csrf_protection'

Devise.setup do |config|
  # Required by Devise even when no mailer-related module is active.
  config.mailer_sender = ENV.fetch('AUTODEV_MAILER_SENDER', 'noreply@autodev.local')

  # Devise normally picks this up from Rails' secret_key_base, but the minimal
  # railtie setup in `config/application.rb` doesn't pull in the secret_key
  # railtie, so we have to set it explicitly. Falls back to a generated value
  # in dev/test if no master key is configured.
  config.secret_key = Rails.application.secret_key_base || SecureRandom.hex(64)

  require 'devise/orm/active_record'

  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]

  # `:http_auth` would otherwise stash creds in the session on every basic-auth
  # request — irrelevant here, kept on the default to avoid surprising Devise.
  config.skip_session_storage = [:http_auth]

  # Tighter than Devise's default — anything below 8 lets bcrypt round-trip
  # faster but is moot since we don't store passwords.
  config.stretches = Rails.env.test? ? 1 : 12

  config.reset_password_within = 6.hours
  config.sign_out_via = :delete

  # Entra ID provider. Tenant scoped to a single org by default; pass
  # `tenant_id: 'common'` to allow any work/school account.
  #
  # Stub credentials when ENV is unset, so:
  #  - `bin/rails server` boots in local dev without crashing — visiting
  #    `/users/auth/entra_id` will fail at the Azure redirect, which is the
  #    expected and visible failure mode.
  #  - integration tests can run `OmniAuth.config.test_mode = true` without
  #    the strategy's middleware-build step exploding on a nil client_id
  #    (the underlying oauth2 gem refuses to construct a Client with
  #    nil credentials, even when test_mode short-circuits the request).
  config.omniauth :entra_id, {
    client_id: ENV.fetch('AZURE_AD_CLIENT_ID', 'stub-client-id'),
    client_secret: ENV.fetch('AZURE_AD_CLIENT_SECRET', 'stub-client-secret'),
    tenant_id: ENV.fetch('AZURE_AD_TENANT_ID', 'common')
  }
end
