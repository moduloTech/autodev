# frozen_string_literal: true

# Validation helpers for Config. Extracted to keep Config module focused on loading.
module ConfigValidator
  LABEL_FIELDS = %w[labels_todo label_doing label_done].freeze

  def self.validate_globals!(config)
    validate_gitlab_token!(config)
    validate_positive_integers!(config)
    validate_log_level!(config)
    validate_web!(config)
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

  def self.validate_web!(config)
    web = config['web']
    return if web.nil?

    raise ConfigError, "'web' must be a hash, got: #{web.inspect}" unless web.is_a?(Hash)

    validate_web_port!(web['port'])
    validate_web_locale!(web['locale'])
    validate_web_bind!(web['bind'])
  end
  private_class_method :validate_web!

  def self.validate_web_port!(port)
    return if port.is_a?(Integer) && port.between?(1024, 65_535)

    raise ConfigError, "'web.port' must be an integer between 1024 and 65535, got: #{port.inspect}"
  end
  private_class_method :validate_web_port!

  def self.validate_web_locale!(locale)
    return if locale.nil? || %w[fr en].include?(locale.to_s)

    raise ConfigError, "'web.locale' must be 'fr' or 'en', got: #{locale.inspect}"
  end
  private_class_method :validate_web_locale!

  # Best-effort check on the bind address. `0.0.0.0`, `127.0.0.1`, any IPv4
  # literal, and any non-empty hostname are all accepted — Puma will surface
  # a clearer error at boot if the address can't be resolved.
  def self.validate_web_bind!(bind)
    return if bind.nil? || (bind.is_a?(String) && !bind.strip.empty?)

    raise ConfigError, "'web.bind' must be a non-empty string, got: #{bind.inspect}"
  end
  private_class_method :validate_web_bind!
end
