# frozen_string_literal: true

# Validation helpers for Config. Extracted to keep Config module focused on loading.
module ConfigValidator
  LABEL_FIELDS = %w[labels_todo label_doing label_mr].freeze

  def self.validate_globals!(config)
    validate_gitlab_token!(config)
    validate_positive_integers!(config)
    validate_log_level!(config)
  end

  def self.validate_project!(project_config, path)
    ProjectValidator.validate!(project_config, path)
  end

  # -- global validation --

  def self.validate_gitlab_token!(config)
    return if config['gitlab_token'].is_a?(String) && !config['gitlab_token'].strip.empty?

    raise ConfigError, 'gitlab_token is required. Set it in config.yml or via GITLAB_API_TOKEN env var.'
  end
  private_class_method :validate_gitlab_token!

  def self.validate_positive_integers!(config)
    Config::INTEGER_FIELDS.each do |field|
      value = config[field]
      unless value.is_a?(Integer) && value.positive?
        raise ConfigError, "'#{field}' must be a positive integer, got: #{value.inspect}"
      end
    end
  end
  private_class_method :validate_positive_integers!

  def self.validate_log_level!(config)
    level = config['log_level'].to_s.upcase
    return if Config::VALID_LOG_LEVELS.include?(level)

    raise ConfigError,
          "'log_level' must be one of #{Config::VALID_LOG_LEVELS.join(', ')}, got: #{config['log_level'].inspect}"
  end
  private_class_method :validate_log_level!
end
