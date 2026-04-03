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
    'gitlab_url' => nil,
    'gitlab_token' => nil,
    'trigger_label' => 'autodev',
    'poll_interval' => 300,
    'max_workers' => 3,
    'dc_timeout' => 1800,
    'max_retries' => 3,
    'retry_backoff' => 30,
    'max_fix_rounds' => 3,
    'log_dir' => File.join(CONFIG_DIR, 'logs'),
    'log_level' => 'INFO',
    'database_url' => "sqlite://#{DEFAULT_DB}",
    'projects' => []
  }.freeze

  ENV_MAPPING = {
    'GITLAB_API_TOKEN' => 'gitlab_token',
    'GITLAB_URL' => 'gitlab_url'
  }.freeze

  def self.load(cli_overrides = {})
    config_path = cli_overrides.delete('config_path') || CONFIG_PATH

    config = DEFAULTS.dup

    if File.exist?(config_path)
      yaml = YAML.safe_load(File.read(config_path), permitted_classes: [Symbol]) || {}
      yaml.each { |k, v| config[k] = v unless v.nil? }
    end

    ENV_MAPPING.each do |env_key, config_key|
      config[config_key] = ENV[env_key] if ENV.key?(env_key)
    end

    cli_overrides.each { |k, v| config[k] = v unless v.nil? }

    config['_config_path'] = config_path

    config['poll_interval'] = config['poll_interval'].to_i
    config['max_workers']   = config['max_workers'].to_i
    config['dc_timeout']    = config['dc_timeout'].to_i
    config['max_retries']    = config['max_retries'].to_i
    config['retry_backoff']  = config['retry_backoff'].to_i
    config['max_fix_rounds'] = config['max_fix_rounds'].to_i

    config
  end

  # Returns true when the project uses the label workflow (all 5 label fields configured).
  # Only checks labels_todo presence — the other 4 fields are guaranteed by validate_projects!
  # which must be called at startup before any label_workflow? check.
  def self.label_workflow?(project_config)
    project_config['labels_todo'].is_a?(Array) && project_config['labels_todo'].any?
  end

  VALID_LOG_LEVELS = %w[DEBUG INFO WARN ERROR].freeze

  # Validate global config. Called at startup before validate_projects!.
  # Raises ConfigError on invalid values.
  def self.validate!(config)
    # Required fields
    unless config['gitlab_token'].is_a?(String) && !config['gitlab_token'].strip.empty?
      raise ConfigError, 'gitlab_token is required. Set it in config.yml or via GITLAB_API_TOKEN env var.'
    end

    # Positive integer globals
    %w[poll_interval max_workers dc_timeout max_retries retry_backoff max_fix_rounds].each do |field|
      value = config[field]
      unless value.is_a?(Integer) && value.positive?
        raise ConfigError, "'#{field}' must be a positive integer, got: #{value.inspect}"
      end
    end

    # Log level
    level = config['log_level'].to_s.upcase
    unless VALID_LOG_LEVELS.include?(level)
      raise ConfigError,
            "'log_level' must be one of #{VALID_LOG_LEVELS.join(', ')}, got: #{config['log_level'].inspect}"
    end

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

      validate_project_numerics!(project_config, path)
      validate_project_post_completion!(project_config, path)
      validate_project_clone_options!(project_config, path)
      validate_project_labels!(project_config, path)
    end
  end

  def self.validate_project_numerics!(project_config, path)
    %w[dc_timeout max_retries retry_backoff max_fix_rounds].each do |field|
      next unless project_config.key?(field)

      value = project_config[field].to_i
      unless value.positive?
        raise ConfigError, "#{path}: '#{field}' must be a positive integer, got: #{project_config[field].inspect}"
      end
    end
  end
  private_class_method :validate_project_numerics!

  def self.validate_project_post_completion!(project_config, path)
    if project_config.key?('post_completion')
      cmd = project_config['post_completion']
      unless cmd.is_a?(Array) && cmd.any? && cmd.all?(String)
        raise ConfigError, "#{path}: 'post_completion' must be a non-empty array of strings."
      end
    end

    if project_config.key?('post_completion_timeout')
      value = project_config['post_completion_timeout'].to_i
      unless value.positive?
        raise ConfigError,
              "#{path}: 'post_completion_timeout' must be a positive integer, " \
              "got: #{project_config['post_completion_timeout'].inspect}"
      end
    end

    return unless project_config.key?('post_completion_timeout') && !project_config.key?('post_completion')

    raise ConfigError, "#{path}: 'post_completion_timeout' is set but 'post_completion' is missing."
  end
  private_class_method :validate_project_post_completion!

  def self.validate_project_clone_options!(project_config, path)
    if project_config.key?('clone_depth')
      value = project_config['clone_depth'].to_i
      if value.negative?
        raise ConfigError,
              "#{path}: 'clone_depth' must be a non-negative integer, got: #{project_config['clone_depth'].inspect}"
      end
    end

    return unless project_config.key?('sparse_checkout')

    paths = project_config['sparse_checkout']
    return if paths.is_a?(Array) && paths.any? && paths.all?(String)

    raise ConfigError, "#{path}: 'sparse_checkout' must be a non-empty array of strings."
  end
  private_class_method :validate_project_clone_options!

  def self.validate_project_labels!(project_config, path)
    label_fields = %w[labels_todo label_doing label_mr label_done label_blocked]
    present = label_fields.select { |f| project_config[f] }

    # Deprecation warnings for old fields
    if project_config['labels_to_remove']
      warn "[DEPRECATION] #{path}: 'labels_to_remove' is deprecated. " \
           "Use 'labels_todo', 'label_doing', 'label_mr', 'label_done', 'label_blocked' instead."
    end
    if project_config['label_to_add']
      warn "[DEPRECATION] #{path}: 'label_to_add' is deprecated. " \
           "Use 'labels_todo', 'label_doing', 'label_mr', 'label_done', 'label_blocked' instead."
    end

    # If any label workflow field is set, all must be set
    return if present.empty?

    missing = label_fields - present
    unless missing.empty?
      raise ConfigError, "#{path}: incomplete label workflow config. Missing: #{missing.join(', ')}. " \
                         "All 5 fields are required: #{label_fields.join(', ')}."
    end

    # Type validation
    unless project_config['labels_todo'].is_a?(Array) && project_config['labels_todo'].any?
      raise ConfigError, "#{path}: 'labels_todo' must be a non-empty array."
    end

    %w[label_doing label_mr label_done label_blocked].each do |field|
      value = project_config[field]
      unless value.is_a?(String) && !value.strip.empty?
        raise ConfigError, "#{path}: '#{field}' must be a non-empty string."
      end
    end
  end
  private_class_method :validate_project_labels!
end
