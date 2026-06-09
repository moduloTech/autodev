# frozen_string_literal: true

# Step 3 of the railsification — server-side session storage in the
# `sessions` table (cf. autodev/docs/autospec.md §C item 3).
#
# Kept narrow on purpose: the cookie still contains only the session id, so
# omniauth's request-phase state (which can be large) lives server-side and
# never bloats subsequent requests. The session id cookie is httponly (set
# by Rails by default).
#
# Explicit requires because `config/application.rb` skips
# `Bundler.require(*Rails.groups)`. Two requires are needed:
#   - `action_dispatch/session/active_record_store` defines the rack
#     middleware referenced by `config.session_store`
#   - `active_record/session_store` defines the AR-backed Session model
#     AND wires `ActionDispatch::Session::ActiveRecordStore.session_class
#     = ActiveRecord::SessionStore::Session`. Without this second require,
#     the middleware boots fine but `session_class` stays nil and any
#     request that writes session data (Mission Control's controllers,
#     anything using `protect_from_forgery`) crashes inside
#     `get_session_model` with `NoMethodError: undefined method 'new'
#     for nil`.
require 'action_dispatch/session/active_record_store'
require 'active_record/session_store'

Rails.application.config.session_store :active_record_store, key: '_autodev_session'
