# frozen_string_literal: true

# This initializer has two jobs, and only the second one is optional.
#
# 1. **Define the `lib/autodev` constants.** `app/` resolves two dozen of them
#    at runtime — `GitlabHelpers`, `Config`, `NumericSettings`, `Locales`,
#    `Redactor`, `ActivityLogger`, `PipelineMonitor`, `IssueProcessor`,
#    `PollRouter`, … — and `lib/` is deliberately kept off the Zeitwerk autoload
#    path (see `config/application.rb`), so this `require` is the *only* thing
#    that defines them in the Rails process. It therefore sits ABOVE the guard
#    below, unconditionally, exactly like the `require 'autodev/migration_status'`
#    at the top of `config/initializers/auto_migrate.rb` (Autodev #55).
#
# 2. **Load `~/.autodev/config.yml` into `Web.config`** so the Phlex views and
#    helpers under `app/components/web/views/` and `app/helpers/web/` can read it
#    (gitlab_url, projects, web.locale, …).
#
# `AUTODEV_SKIP_LEGACY=1` skips job 2 only. What that flag protects is the *disk
# read*: `Config.load` reads the developer's real `~/.autodev/config.yml` — real
# GitLab token, real project list — and raises `ConfigError` when the file is
# absent. No test may depend on either, which is why `test/rails_helper.rb` sets
# the flag.
#
# It used to skip job 1 as well, and that is the whole of Autodev #64. Under the
# flag the `lib/` constants existed in a test process only because some *other*
# test file had already required them, so the full suite passed while the same
# file run alone raised `NameError` — a failure mode invisible in integration and
# visible exactly when iterating on one file. Nine ad-hoc `require`s had
# accumulated in `test/rails_helper.rb` to paper over it, five of them carrying
# this same explanation; measured, 40 of 193 test files depended on that
# hand-maintained list. There is no useful "pure utilities" subset to load
# instead: the constants `app/` reaches for include the workflow classes
# (`PipelineMonitor`, `MrFixer`, `IssueProcessor`), so the honest cut is the
# whole tree, once, at boot, in every environment. It costs the `gitlab`,
# `pastel`, `phlex` and `sqlite3` requires that `lib/autodev.rb` performs —
# already paid by the Sequel-side `test/test_helper.rb`, which never set the
# flag.
#
# The file name is a leftover from when this initializer also bridged Sinatra
# into the Rails process — step 8 retired all of that.

require_relative '../../lib/autodev'

return if ENV['AUTODEV_SKIP_LEGACY']

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
