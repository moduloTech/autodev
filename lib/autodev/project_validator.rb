# frozen_string_literal: true

# Per-project validation helpers, extracted from ConfigValidator.
module ProjectValidator
  def self.validate!(project_config, path)
    validate_numerics!(project_config, path)
    validate_post_completion!(project_config, path)
    validate_clone_options!(project_config, path)
    validate_labels!(project_config, path)
    AppValidator.validate!(project_config, path)
  end

  def self.validate_numerics!(project_config, path)
    %w[dc_timeout max_retries retry_backoff stagnation_threshold].each do |field|
      next unless project_config.key?(field)

      value = project_config[field].to_i
      unless value.positive?
        raise ConfigError, "#{path}: '#{field}' must be a positive integer, got: #{project_config[field].inspect}"
      end
    end
  end
  private_class_method :validate_numerics!

  def self.validate_post_completion!(project_config, path)
    validate_post_completion_cmd!(project_config, path)
    validate_post_completion_timeout!(project_config, path)
    return unless project_config.key?('post_completion_timeout') && !project_config.key?('post_completion')

    raise ConfigError, "#{path}: 'post_completion_timeout' is set but 'post_completion' is missing."
  end
  private_class_method :validate_post_completion!

  def self.validate_post_completion_cmd!(project_config, path)
    return unless project_config.key?('post_completion')

    cmd = project_config['post_completion']
    return if cmd.is_a?(Array) && cmd.any? && cmd.all?(String)

    raise ConfigError, "#{path}: 'post_completion' must be a non-empty array of strings."
  end
  private_class_method :validate_post_completion_cmd!

  def self.validate_post_completion_timeout!(project_config, path)
    return unless project_config.key?('post_completion_timeout')

    value = project_config['post_completion_timeout'].to_i
    return if value.positive?

    raise ConfigError,
          "#{path}: 'post_completion_timeout' must be a positive integer, " \
          "got: #{project_config['post_completion_timeout'].inspect}"
  end
  private_class_method :validate_post_completion_timeout!

  def self.validate_clone_options!(project_config, path)
    validate_clone_depth!(project_config, path)
    validate_sparse_checkout!(project_config, path)
  end
  private_class_method :validate_clone_options!

  def self.validate_clone_depth!(project_config, path)
    return unless project_config.key?('clone_depth')

    value = project_config['clone_depth'].to_i
    return unless value.negative?

    raise ConfigError,
          "#{path}: 'clone_depth' must be a non-negative integer, got: #{project_config['clone_depth'].inspect}"
  end
  private_class_method :validate_clone_depth!

  def self.validate_sparse_checkout!(project_config, path)
    return unless project_config.key?('sparse_checkout')

    paths = project_config['sparse_checkout']
    return if paths.is_a?(Array) && paths.any? && paths.all?(String)

    raise ConfigError, "#{path}: 'sparse_checkout' must be a non-empty array of strings."
  end
  private_class_method :validate_sparse_checkout!

  def self.validate_labels!(project_config, path)
    present = ConfigValidator::LABEL_FIELDS.select { |f| project_config[f] }
    warn_deprecated_label_fields!(project_config, path)
    return if present.empty?

    validate_label_completeness!(present, path)
    validate_label_types!(project_config, path)
  end
  private_class_method :validate_labels!

  def self.warn_deprecated_label_fields!(project_config, path)
    %w[labels_to_remove label_to_add label_done label_blocked max_fix_rounds].each do |field|
      next unless project_config[field]

      warn "[DEPRECATION] #{path}: '#{field}' is deprecated and will be removed in a future version."
    end
  end
  private_class_method :warn_deprecated_label_fields!

  def self.validate_label_completeness!(present, path)
    missing = ConfigValidator::LABEL_FIELDS - present
    return if missing.empty?

    raise ConfigError, "#{path}: incomplete label workflow config. Missing: #{missing.join(', ')}. " \
                       "All 5 fields are required: #{ConfigValidator::LABEL_FIELDS.join(', ')}."
  end
  private_class_method :validate_label_completeness!

  def self.validate_label_types!(project_config, path)
    unless project_config['labels_todo'].is_a?(Array) && project_config['labels_todo'].any?
      raise ConfigError, "#{path}: 'labels_todo' must be a non-empty array."
    end

    %w[label_doing label_mr].each do |field|
      value = project_config[field]
      unless value.is_a?(String) && !value.strip.empty?
        raise ConfigError, "#{path}: '#{field}' must be a non-empty string."
      end
    end
  end
  private_class_method :validate_label_types!
end
