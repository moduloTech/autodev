# frozen_string_literal: true

# Step 3 of the railsification — server-side session storage in the
# `sessions` table (cf. autodev/docs/autospec.md §C item 3).
#
# Kept narrow on purpose: the cookie still contains only the session id, so
# omniauth's request-phase state (which can be large) lives server-side and
# never bloats subsequent requests. The session id cookie is httponly (set
# by Rails by default).
#
# Explicit require because `config/application.rb` skips
# `Bundler.require(*Rails.groups)` (to keep Sequel/Sinatra out of the Rails
# process) — without it, `ActionDispatch::Session::ActiveRecordStore`
# is not constantized at `Rails.application.config.session_store` resolution.
require 'action_dispatch/session/active_record_store'

Rails.application.config.session_store :active_record_store, key: '_autodev_session'
