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

Rails.application.config.after_initialize do
  Web.config = Config.load({})
end
