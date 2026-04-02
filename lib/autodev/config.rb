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
        #
        # -- Label workflow (all 5 required) --
        # labels_todo:                           # labels that trigger full processing
        #   - "development::todo"
        #   - "todo"
        # label_doing: "Development::Doing"      # set during active processing
        # label_mr: "Development::Awaiting CR"   # set after MR creation, triggers discussion monitoring
        # label_done: "Development::Done"         # set by reviewer to signal completion
        # label_blocked: "Development::Blocked"   # set when issue is blocked
        #
        # -- Deprecated (use label workflow instead) --
        # labels_to_remove: []
        # label_to_add: ""
        #
        # extra_prompt: "Use RSpec for tests"   # additional instructions for Claude
        # dc_timeout: 1800                        # danger-claude timeout in seconds (overrides global)
        # max_retries: 3                          # max retries per issue (overrides global)
        # retry_backoff: 30                       # base backoff seconds (overrides global)
        # max_fix_rounds: 3                       # max MR comment fix rounds (overrides global)
        # clone_depth: 1                         # git clone depth (0 = full clone, default: 1)
        # sparse_checkout:                       # sparse checkout paths (for monorepos)
        #   - "src/"
        #   - "lib/"
        # post_completion: ["./bin/deploy", "--env", "staging"]  # command run after pipeline green (Docker CMD format)
        # post_completion_timeout: 300                            # timeout in seconds (default: 300)
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

  # Returns true when the project uses the label workflow (all 5 label fields configured).
  # Only checks labels_todo presence — the other 4 fields are guaranteed by validate_projects!
  # which must be called at startup before any label_workflow? check.
  def self.label_workflow?(project_config)
    project_config["labels_todo"].is_a?(Array) && project_config["labels_todo"].any?
  end

  # Validate label workflow config for all projects. Called at startup.
  # Raises ConfigError if config is incomplete.
  def self.validate_projects!(config)
    label_fields = %w[labels_todo label_doing label_mr label_done label_blocked]

    (config["projects"] || []).each do |project_config|
      path = project_config["path"]
      present = label_fields.select { |f| project_config[f] }

      # Deprecation warnings for old fields
      if project_config["labels_to_remove"]
        $stderr.puts "[DEPRECATION] #{path}: 'labels_to_remove' is deprecated. Use 'labels_todo', 'label_doing', 'label_mr', 'label_done', 'label_blocked' instead."
      end
      if project_config["label_to_add"]
        $stderr.puts "[DEPRECATION] #{path}: 'label_to_add' is deprecated. Use 'labels_todo', 'label_doing', 'label_mr', 'label_done', 'label_blocked' instead."
      end

      # If any label workflow field is set, all must be set
      next if present.empty?

      missing = label_fields - present
      unless missing.empty?
        raise ConfigError, "#{path}: incomplete label workflow config. Missing: #{missing.join(", ")}. " \
                           "All 5 fields are required: #{label_fields.join(", ")}."
      end

      # Type validation
      unless project_config["labels_todo"].is_a?(Array) && project_config["labels_todo"].any?
        raise ConfigError, "#{path}: 'labels_todo' must be a non-empty array."
      end

      %w[label_doing label_mr label_done label_blocked].each do |field|
        value = project_config[field]
        unless value.is_a?(String) && !value.strip.empty?
          raise ConfigError, "#{path}: '#{field}' must be a non-empty string."
        end
      end
    end
  end
end
