# frozen_string_literal: true

# Validation helpers for Config. Extracted to keep Config module focused on loading.
module ConfigValidator
  LABEL_FIELDS = %w[labels_todo label_doing label_done].freeze
  # "If set, must not be blank" fields (checked by
  # ProjectValidator.validate_optional_string_fields!): a present-and-blank
  # value is a typo, and it would otherwise read as "not configured" and
  # silently take the fallback.
  #
  # `label_attention` (Autodev #63): the label a give-up poses instead of
  # `label_done`. Optional because the scope autodev derives from `label_doing`
  # + `label_done` names a scope, not its values: powerpanne/core has
  # `Development::StandBy` / `Awaiting CR` / `Awaiting Merge` to choose from,
  # ff/fast/core only `NeedEstimation` — there is no third value autodev can
  # derive. Unset means no end label at all on a give-up, so the row keeps
  # `label_doing`.
  #
  # `review_skill` (Autodev #74): the skill the review step loads from the
  # cloned repo. Unset means the `mr-review` binary.
  OPTIONAL_STRING_FIELDS = %w[label_attention review_skill].freeze

  def self.validate_globals!(config)
    validate_gitlab_token!(config)
    validate_mr_review_token!(config)
    validate_numeric_settings!(config)
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

  # Optional, and refused when present-and-blank (Autodev #80): unset means
  # "mr-review shares `gitlab_token`", so a blank would read as that fallback
  # while looking like a separation. Same rule as the optional per-project
  # strings above, applied to a global.
  #
  # No value check beyond that. Whether the token is *accepted* is not a question
  # a validator can answer, and it is the question this ticket is actually about:
  # `Autodev::MrReviewTokenProbe` asks GitLab once per cycle, but only while some
  # project still reviews through the binary.
  def self.validate_mr_review_token!(config)
    value = config['mr_review_token']
    return if value.nil?
    return if value.is_a?(String) && !value.strip.empty?

    raise ConfigError, "'mr_review_token', if set, must be a non-empty string. " \
                       'Remove it to share gitlab_token with mr-review.'
  end
  private_class_method :validate_mr_review_token!

  # Every numeric global is checked against its NumericSettings declaration
  # (Autodev #58) rather than against one blanket "> 0" rule. The mandatory
  # ones must be present; the rest are only checked when the operator set them,
  # since an absent optional key means "use the default".
  def self.validate_numeric_settings!(config)
    Config::REQUIRED_NUMERIC_GLOBALS.each do |field|
      raise ConfigError, "'#{field}' is required." unless config.key?(field)
    end
    NumericSettings.fields.each do |field|
      next unless config.key?(field)

      reason = NumericSettings.violation(field, config[field])
      raise ConfigError, NumericSettings.config_error_message(field, config[field]) if reason
    end
    validate_monitoring_settings!(config)
  end
  private_class_method :validate_numeric_settings!

  # The `monitoring:` block gets the same refusal as the flat globals. It was the
  # gap #58 left: nested keys were outside the registry, and two settings landed
  # in it in the same release reading `(value || DEFAULT).to_i`, where a typo
  # switched a protection off instead of failing.
  def self.validate_monitoring_settings!(config)
    block = config['monitoring']
    return unless block.is_a?(Hash)

    NumericSettings::MONITORING_FIELDS.each do |field|
      raw = block[field]
      next if raw.nil?

      reason = NumericSettings.monitoring_violation(field, raw)
      raise ConfigError, NumericSettings.monitoring_error_message(field, raw) if reason
    end
  end
  private_class_method :validate_monitoring_settings!

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
