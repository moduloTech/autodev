# frozen_string_literal: true

# Loads `~/.autodev/config.yml` into `Web.config` so the Phlex views +
# helpers under `app/components/web/views/` and `app/helpers/web/` can
# read it (gitlab_url, projects, web.locale, etc.).
#
# The file name is a leftover from when this initializer also bridged
# Sinatra into the Rails process — step 8 retired all of that. The
# remaining job is just to pull config into a module-level accessor.
#
# Set AUTODEV_SKIP_LEGACY=1 to skip the whole block — useful for tests
# that don't need ~/.autodev/config.yml on disk.

return if ENV['AUTODEV_SKIP_LEGACY']

require_relative '../../lib/autodev'

# `to_prepare` instead of `after_initialize`: in development, Zeitwerk reloads
# autoloaded constants on file change. `Web` lives in `app/services/web.rb`,
# so on each reload the module is re-defined and `Web.config` reverts to nil.
# `after_initialize` only fires once at boot, so any post-reload request that
# reads through `Web.config` (e.g. `Autodev::GitlabMembershipSync` during the
# OAuth callback) hits ConfigError. `to_prepare` re-runs after every reload in
# dev and still runs once at boot in production.
Rails.application.config.to_prepare do
  Web.config = Config.load({})
end
