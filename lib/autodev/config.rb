# frozen_string_literal: true

# Configuration loading, validation, and CLI argument parsing for autodev.
module Config
  CONFIG_DIR  = File.expand_path('~/.autodev')
  CONFIG_PATH = File.join(CONFIG_DIR, 'config.yml')
  DEFAULT_DB  = File.join(CONFIG_DIR, 'autodev.db')

  TEMPLATE = <<~YAML
    # autodev configuration
    # See: https://github.com/moduloTech/autodev

    gitlab_url: https://gitlab.example.com
    gitlab_token: glpat-xxxxxxxxxxxxxxxxxxxx   # or set GITLAB_API_TOKEN env var
    poll_interval: 300                          # seconds between poll cycles
    max_workers: 3                              # concurrent worker threads
    dc_timeout: 1800                              # danger-claude timeout in seconds (default: 1800 = 30min)
    max_retries: 3                                 # max retry attempts per issue (default: 3)
    retry_backoff: 30                              # base backoff in seconds, doubles each retry (default: 30)
    pickup_delay: 600                               # seconds before processing a new issue (default: 600 = 10min)
    stagnation_threshold: 5                         # consecutive identical failures before giving up (default: 5)
    log_dir: ~/.autodev/logs                       # log directory (default: ~/.autodev/logs)
    log_level: INFO                                # DEBUG, INFO, WARN, ERROR (default: INFO)
    # database_url: sqlite://~/.autodev/autodev.db  # default


    projects:
      - path: group/project-name
        # target_branch: develop                # optional, defaults to project default branch
        #
        # -- Label workflow (all 3 required) --
        # labels_todo:                           # labels that trigger full processing
        #   - "development::todo"
        #   - "todo"
        # label_doing: "Development::Doing"      # set during active processing
        # label_mr: "Development::Awaiting CR"   # set when issue reaches done state
        #
        # -- Deprecated (use label workflow instead) --
        # labels_to_remove: []
        # label_to_add: ""
        #
        # extra_prompt: "Use RSpec for tests"   # additional instructions for Claude
        # dc_timeout: 1800                        # danger-claude timeout in seconds (overrides global)
        # max_retries: 3                          # max retries per issue (overrides global)
        # retry_backoff: 30                       # base backoff seconds (overrides global)
        # stagnation_threshold: 5                  # consecutive identical failures threshold (overrides global)
        # clone_depth: 1                         # git clone depth (0 = full clone, default: 1)
        # sparse_checkout:                       # sparse checkout paths (for monorepos)
        #   - "src/"
        #   - "lib/"
        # post_completion: ["./bin/deploy", "--env", "staging"]  # command run after pipeline green (Docker CMD format)
        # post_completion_timeout: 300                            # timeout in seconds (default: 300)
        #
        # app:                                    # app environment instructions for danger-claude
        #   setup:                                # dependency installation commands
        #     - ["bundle", "install"]
        #     - ["yarn", "install"]
        #   test:                                 # test commands
        #     - ["bin/test"]
        #   lint:                                 # lint / auto-fix commands
        #     - ["bundle", "exec", "rubocop", "-A"]
        #   run:                                  # background servers (port exposed to host for Chrome)
        #     - command: ["bin/rails", "s"]
        #       port: 3000
        #     - command: ["bin/vite", "dev"]
  YAML

  DEFAULTS = {
    'gitlab_url' => nil,
    'gitlab_token' => nil,
    'poll_interval' => 300,
    'max_workers' => 3,
    'dc_timeout' => 1800,
    'max_retries' => 3,
    'retry_backoff' => 30,
    'pickup_delay' => 600,
    'stagnation_threshold' => 5,
    'log_dir' => File.join(CONFIG_DIR, 'logs'),
    'log_level' => 'INFO',
    'database_url' => "sqlite://#{DEFAULT_DB}",
    'projects' => []
  }.freeze

  ENV_MAPPING = {
    'GITLAB_API_TOKEN' => 'gitlab_token',
    'GITLAB_URL' => 'gitlab_url'
  }.freeze

  DEPRECATED_GLOBAL_FIELDS = %w[trigger_label max_fix_rounds].freeze

  INTEGER_FIELDS = %w[poll_interval max_workers dc_timeout max_retries retry_backoff pickup_delay
                      stagnation_threshold].freeze
  VALID_LOG_LEVELS = %w[DEBUG INFO WARN ERROR].freeze

  def self.load(cli_overrides = {})
    config_path = cli_overrides.delete('config_path') || CONFIG_PATH
    config = DEFAULTS.dup
    merge_yaml!(config, config_path)
    merge_env!(config)
    cli_overrides.each { |k, v| config[k] = v unless v.nil? }
    config['_config_path'] = config_path
    coerce_integers!(config)
    warn_deprecated!(config)
    config
  end

  # Returns true when the project uses the label workflow (all 5 label fields configured).
  # Only checks labels_todo presence — the other 4 fields are guaranteed by validate_projects!
  # which must be called at startup before any label_workflow? check.
  def self.label_workflow?(project_config)
    project_config['labels_todo'].is_a?(Array) && project_config['labels_todo'].any?
  end

  # Returns true when any project has app.run entries with exposed ports,
  # meaning Chrome DevTools must be launched for screenshot support.
  def self.chrome_devtools_needed?(config)
    (config['projects'] || []).any? { |p| project_has_exposed_ports?(p) }
  end

  # Returns true when this specific project has app.run entries with exposed ports.
  def self.project_has_exposed_ports?(project_config)
    entries = project_config.dig('app', 'run')
    entries.is_a?(Array) && entries.any? { |e| e.is_a?(Hash) && e['port'] }
  end

  # Validate global config. Called at startup before validate_projects!.
  # Raises ConfigError on invalid values.
  def self.validate!(config)
    ConfigValidator.validate_globals!(config)
    validate_projects!(config)
  end

  # Validate per-project config for all projects. Called by validate!.
  # Raises ConfigError if config is incomplete or invalid.
  def self.validate_projects!(config)
    (config['projects'] || []).each_with_index do |project_config, idx|
      path = project_config['path']
      unless path.is_a?(String) && !path.strip.empty?
        raise ConfigError, "projects[#{idx}]: 'path' is required and must be a non-empty string."
      end

      ConfigValidator.validate_project!(project_config, path)
    end
  end

  # -- load helpers --

  def self.merge_yaml!(config, config_path)
    return unless File.exist?(config_path)

    yaml = YAML.safe_load_file(config_path, permitted_classes: [Symbol]) || {}
    yaml.each { |k, v| config[k] = v unless v.nil? }
  end
  private_class_method :merge_yaml!

  def self.merge_env!(config)
    ENV_MAPPING.each do |env_key, config_key|
      config[config_key] = ENV[env_key] if ENV.key?(env_key)
    end
  end
  private_class_method :merge_env!

  def self.coerce_integers!(config)
    INTEGER_FIELDS.each { |f| config[f] = config[f].to_i }
  end
  private_class_method :coerce_integers!

  def self.warn_deprecated!(config)
    DEPRECATED_GLOBAL_FIELDS.each do |field|
      next unless config.key?(field) && !DEFAULTS.key?(field)

      warn "[DEPRECATION] '#{field}' is deprecated and will be removed in a future version."
    end
  end
  private_class_method :warn_deprecated!
end
