# frozen_string_literal: true

# Per-project validation helpers, extracted from ConfigValidator.
module ProjectValidator
  def self.validate!(project_config, path)
    validate_numerics!(project_config, path)
    validate_post_completion!(project_config, path)
    validate_clone_options!(project_config, path)
    validate_labels!(project_config, path)
    AdvancedValidator.validate!(project_config, path)
    AppValidator.validate!(project_config, path)
  end

  # Every numeric per-project override is checked against its NumericSettings
  # declaration (Autodev #58). Enumerating the declarations instead of a local
  # list is what makes a new numeric setting a one-line addition, and it is how
  # `clone_depth` (0 = full clone) and `pipeline_watch_max_days` (0 = bound
  # disabled) stop needing hand-written special cases: their declared floor is
  # 0, which is a statement about the range and no longer doubles as permission
  # for any value that happens to coerce to 0.
  def self.validate_numerics!(project_config, path)
    NumericSettings.fields.each do |field|
      next unless project_config.key?(field)

      value = project_config[field]
      next unless NumericSettings.violation(field, value)

      raise ConfigError, NumericSettings.config_error_message(field, value, scope: path)
    end
  end
  private_class_method :validate_numerics!

  def self.validate_post_completion!(project_config, path)
    validate_post_completion_cmd!(project_config, path)
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

  # `post_completion_timeout` and `clone_depth` are numeric, so their bounds are
  # applied by `validate_numerics!` from their NumericSettings declaration. What
  # is left here is the non-numeric half: sparse_checkout's shape, and (in
  # `validate_post_completion!`) the pairing rule.
  def self.validate_clone_options!(project_config, path)
    validate_sparse_checkout!(project_config, path)
  end
  private_class_method :validate_clone_options!

  def self.validate_sparse_checkout!(project_config, path)
    return unless project_config.key?('sparse_checkout')

    paths = project_config['sparse_checkout']
    return if paths.is_a?(Array) && paths.any? && paths.all?(String)

    raise ConfigError, "#{path}: 'sparse_checkout' must be a non-empty array of strings."
  end
  private_class_method :validate_sparse_checkout!

  def self.validate_labels!(project_config, path)
    present = ConfigValidator::LABEL_FIELDS.select { |f| project_config[f] }
    return if present.empty? && !project_config.key?('label_attention')

    validate_label_completeness!(present, path)
    validate_label_types!(project_config, path)
  end
  private_class_method :validate_labels!

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

    %w[label_doing label_done].each do |field|
      value = project_config[field]
      unless value.is_a?(String) && !value.strip.empty?
        raise ConfigError, "#{path}: '#{field}' must be a non-empty string."
      end
    end
    validate_optional_string_fields!(project_config, path)
  end
  private_class_method :validate_label_types!

  # `label_attention` (Autodev #63) and `review_skill` (Autodev #74) are
  # optional — most projects have no third label-workflow value and no project
  # review skill, and either's absence is a defined fallback (no end label on a
  # give-up; the `mr-review` binary for review), not a partial config. But a
  # present-and-blank value is a typo, and it would otherwise read as "not
  # configured" and silently take the fallback.
  def self.validate_optional_string_fields!(project_config, path)
    ConfigValidator::OPTIONAL_STRING_FIELDS.each do |field|
      next unless project_config.key?(field)

      value = project_config[field]
      next if value.is_a?(String) && !value.strip.empty?

      raise ConfigError, "#{path}: '#{field}' must be a non-empty string when set."
    end
  end
  private_class_method :validate_optional_string_fields!
end
