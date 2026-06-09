# frozen_string_literal: true

require 'fileutils'
require 'securerandom'

Rails.application.configure do
  config.enable_reloading = false
  # `eager_load = false` because our minimal railtie set omits action_mailer,
  # so Devise's `app/mailers/devise/mailer.rb` Zeitwerk-fails when eagerly
  # loaded ("expected ... to define constant Devise::Mailer, but didn't").
  # Autodev's traffic is single-user / single-process — autoload-on-demand
  # is fine and lets us skip the action_mailer railtie entirely.
  config.eager_load = false
  config.consider_all_requests_local = false
  config.active_support.deprecation = :stderr

  # When installed via Homebrew, `Rails.root` is the read-only cellar
  # (/opt/homebrew/Cellar/autodev/<ver>/) — Rails defaults log to
  # `Rails.root/log/<env>.log` and tmp to `Rails.root/tmp/`, both of
  # which would EACCES on first write. Redirect both to a user-owned
  # directory under `~/.autodev/` so the install location stays
  # immutable and only ~/.autodev/ accumulates state. Set
  # AUTODEV_HOME=/somewhere/else to relocate (e.g. a service account).
  autodev_home = ENV['AUTODEV_HOME'] || File.expand_path('~/.autodev')
  FileUtils.mkdir_p(File.join(autodev_home, 'log'))
  FileUtils.mkdir_p(File.join(autodev_home, 'tmp'))

  log_path = File.join(autodev_home, 'log', "#{Rails.env}.log")
  config.paths['log'] = log_path
  config.logger = ActiveSupport::Logger.new(log_path)
  config.logger.formatter = Logger::Formatter.new

  # Rails.root.join('tmp') is used by ActiveRecord (cached SQL) and
  # Solid Queue (process pid files). Override via the same env var.
  ENV['RAILS_TMP_PATH'] ||= File.join(autodev_home, 'tmp')

  # Devise + activerecord-session_store need a stable secret_key_base in
  # production. We don't ship `config/credentials.yml.enc` (single-user
  # CLI, encrypting one machine's secret against another doesn't help),
  # so we generate-and-persist a fresh secret under `~/.autodev/` on
  # first boot. Permission 0600 keeps it private to the running user.
  secret_path = File.join(autodev_home, 'secret_key_base')
  unless File.exist?(secret_path)
    File.write(secret_path, SecureRandom.hex(64))
    File.chmod(0o600, secret_path)
  end
  config.secret_key_base = File.read(secret_path).strip
end
