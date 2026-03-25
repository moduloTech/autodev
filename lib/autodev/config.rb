# frozen_string_literal: true

module Config
  CONFIG_DIR  = File.expand_path("~/.autodev")
  CONFIG_PATH = File.join(CONFIG_DIR, "config.yml")
  DEFAULT_DB  = File.join(CONFIG_DIR, "autodev.db")

  TEMPLATE = <<~YAML
    # autodev configuration
    # See: https://github.com/moduloTech/autodev

    gitlab_url: https://gitlab.example.com
    gitlab_token: glpat-xxxxxxxxxxxxxxxxxxxx   # or set GITLAB_API_TOKEN env var
    trigger_label: autodev                      # label that triggers processing
    poll_interval: 300                          # seconds between poll cycles
    max_workers: 3                              # concurrent worker threads
    dc_timeout: 1800                              # danger-claude timeout in seconds (default: 1800 = 30min)
    max_retries: 3                                 # max retry attempts per issue (default: 3)
    retry_backoff: 30                              # base backoff in seconds, doubles each retry (default: 30)
    max_fix_rounds: 3                              # max MR comment fix rounds per issue (default: 3)
    log_dir: ~/.autodev/logs                       # log directory (default: ~/.autodev/logs)
    log_level: INFO                                # DEBUG, INFO, WARN, ERROR (default: INFO)
    # database_url: sqlite://~/.autodev/autodev.db  # default

    projects:
      - path: group/project-name
        # target_branch: develop                # optional, defaults to project default branch
        # labels_to_remove:                     # labels to remove after MR creation
        #   - "development::todo"
        #   - "todo"
        # label_to_add: "Development::Awaiting CR"
        # extra_prompt: "Use RSpec for tests"   # additional instructions for Claude
        # dc_timeout: 1800                        # danger-claude timeout in seconds (overrides global)
        # max_retries: 3                          # max retries per issue (overrides global)
        # retry_backoff: 30                       # base backoff seconds (overrides global)
        # max_fix_rounds: 3                       # max MR comment fix rounds (overrides global)
        # clone_depth: 1                         # git clone depth (0 = full clone, default: 1)
        # sparse_checkout:                       # sparse checkout paths (for monorepos)
        #   - "src/"
        #   - "lib/"
  YAML

  DEFAULTS = {
    "gitlab_url"     => nil,
    "gitlab_token"   => nil,
    "trigger_label"  => "autodev",
    "poll_interval"  => 300,
    "max_workers"    => 3,
    "dc_timeout"     => 1800,
    "max_retries"    => 3,
    "retry_backoff"  => 30,
    "max_fix_rounds" => 3,
    "log_dir"        => File.join(CONFIG_DIR, "logs"),
    "log_level"      => "INFO",
    "database_url"   => "sqlite://#{DEFAULT_DB}",
    "projects"       => []
  }.freeze

  ENV_MAPPING = {
    "GITLAB_API_TOKEN" => "gitlab_token",
    "GITLAB_URL"       => "gitlab_url"
  }.freeze

  def self.load(cli_overrides = {})
    config_path = cli_overrides.delete("config_path") || CONFIG_PATH

    config = DEFAULTS.dup

    if File.exist?(config_path)
      yaml = YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
      yaml.each { |k, v| config[k] = v unless v.nil? }
    end

    ENV_MAPPING.each do |env_key, config_key|
      config[config_key] = ENV[env_key] if ENV.key?(env_key)
    end

    cli_overrides.each { |k, v| config[k] = v unless v.nil? }

    config["_config_path"] = config_path

    config["poll_interval"] = config["poll_interval"].to_i
    config["max_workers"]   = config["max_workers"].to_i
    config["dc_timeout"]    = config["dc_timeout"].to_i
    config["max_retries"]    = config["max_retries"].to_i
    config["retry_backoff"]  = config["retry_backoff"].to_i
    config["max_fix_rounds"] = config["max_fix_rounds"].to_i

    config
  end
end
