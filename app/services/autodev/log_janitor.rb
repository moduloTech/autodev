# frozen_string_literal: true

require 'fileutils'

module Autodev
  # Bounds log growth so ~/.autodev/log never fills the disk.
  #
  # Two mechanisms, because the files differ:
  #
  #   - The AppLogger JSONL files (`<log_dir>/**/*.jsonl`) are already rotated
  #     daily (date-stamped filenames), so we only PRUNE the ones past the
  #     retention window.
  #   - The Rails log (`<env>.log`) and the launchd-captured supervisor
  #     output (`autodev-stdout.log` / `autodev-stderr.log`) are single files
  #     held open by several long-lived processes. A daily rename can't rotate
  #     them — every fd would follow the renamed inode. So we COPY-TRUNCATE:
  #     copy the contents to a timestamped archive, then truncate the original
  #     in place (the held fds keep appending from offset 0). Archives are then
  #     pruned like everything else.
  #
  # Retention and the size cap are baked constants (no config keys, in keeping
  # with the "minimal config.yml" direction). Run daily by LogJanitorJob.
  class LogJanitor
    RETENTION_DAYS = 30
    MAX_BYTES = 50 * 1024 * 1024
    SUPERVISOR_LOGS = %w[autodev-stdout.log autodev-stderr.log].freeze

    def self.run(**)
      new(**).run
    end

    def self.default_home
      ENV['AUTODEV_HOME'] || File.expand_path('~/.autodev')
    end

    def self.default_app_log_dir(home)
      configured = Web.config['log_dir'] if defined?(Web) && Web.config.is_a?(Hash)
      File.expand_path(configured || File.join(home, 'logs'))
    end

    def initialize(home: self.class.default_home, app_log_dir: nil, rails_env: Rails.env,
                   max_bytes: MAX_BYTES, now: Time.now)
      @home = home
      @app_log_dir = app_log_dir || self.class.default_app_log_dir(home)
      @rails_env = rails_env.to_s
      @max_bytes = max_bytes
      @now = now
    end

    # Returns { rotated: [paths], pruned: count } for logging/testing.
    def run
      { rotated: rotate_held_logs, pruned: prune_stale_files }
    end

    private

    def cutoff
      @now - (RETENTION_DAYS * 86_400)
    end

    def rails_log_dir
      File.join(@home, 'log')
    end

    # `<env>.log` + the two supervisor capture files.
    def held_log_paths
      (["#{@rails_env}.log"] + SUPERVISOR_LOGS).map { |name| File.join(rails_log_dir, name) }
    end

    def rotate_held_logs
      held_log_paths.select { |path| File.file?(path) && File.size(path) > @max_bytes }
                    .each { |path| copy_truncate(path) }
    end

    def copy_truncate(path)
      archive = "#{path}.#{@now.strftime('%Y%m%d-%H%M%S')}"
      FileUtils.cp(path, archive)
      File.truncate(path, 0)
    end

    # Date-stamped JSONL files + rotation archives older than the window.
    # The active files (today's JSONL, the live `<env>.log`, the supervisor
    # files) keep a recent mtime, so they're never selected.
    def prune_stale_files
      stale = (jsonl_files + archive_files).select { |f| File.mtime(f) < cutoff }
      stale.each { |f| File.delete(f) }.size
    end

    def jsonl_files
      Dir.glob(File.join(@app_log_dir, '**', '*.jsonl'))
    end

    def archive_files
      Dir.glob(File.join(rails_log_dir, '*.log.*'))
    end
  end
end
