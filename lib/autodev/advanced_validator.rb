# frozen_string_literal: true

# Validates the per-project "advanced" config keys columnized in task #9
# phase 2 (model / effort / *_agent strings, parallel_agents /
# split_implementation booleans). Mirrors the model-side validations on
# `Project`. Extracted from ProjectValidator to keep that module's length in
# check, same split as AppValidator.
module AdvancedValidator
  STRING_FIELDS = %w[model effort implementer_agent test_writer_agent mr_fixer_agent].freeze
  BOOLEAN_FIELDS = %w[parallel_agents split_implementation].freeze

  def self.validate!(project_config, path)
    STRING_FIELDS.each { |field| validate_string!(project_config, field, path) }
    BOOLEAN_FIELDS.each { |field| validate_boolean!(project_config, field, path) }
  end

  def self.validate_string!(project_config, field, path)
    return unless project_config.key?(field)

    value = project_config[field]
    return if value.is_a?(String) && !value.strip.empty?

    raise ConfigError, "#{path}: '#{field}' must be a non-empty string."
  end
  private_class_method :validate_string!

  def self.validate_boolean!(project_config, field, path)
    return unless project_config.key?(field)
    return if [true, false].include?(project_config[field])

    raise ConfigError, "#{path}: '#{field}' must be true or false."
  end
  private_class_method :validate_boolean!
end
