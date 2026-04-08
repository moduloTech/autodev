# frozen_string_literal: true

# Validates the per-project `app:` configuration block (setup/test/lint commands).
module AppValidator
  SECTIONS = %w[setup test lint].freeze

  def self.validate!(project_config, path)
    return unless project_config.key?('app')

    app = project_config['app']
    validate_type!(app, path)
    validate_keys!(app, path)
    SECTIONS.each { |section| validate_section!(app, section, path) }
  end

  def self.validate_type!(app, path)
    return if app.is_a?(Hash)

    raise ConfigError, "#{path}: 'app' must be a mapping with optional keys: #{SECTIONS.join(', ')}."
  end
  private_class_method :validate_type!

  def self.validate_keys!(app, path)
    unknown = app.keys - SECTIONS
    return if unknown.empty?

    raise ConfigError, "#{path}: unknown app keys: #{unknown.join(', ')}. Allowed: #{SECTIONS.join(', ')}."
  end
  private_class_method :validate_keys!

  def self.validate_section!(app, section, path)
    return unless app.key?(section)

    cmds = app[section]
    unless cmds.is_a?(Array) && cmds.any?
      raise ConfigError, "#{path}: 'app.#{section}' must be a non-empty array of commands."
    end

    validate_commands!(cmds, section, path)
  end
  private_class_method :validate_section!

  def self.validate_commands!(cmds, section, path)
    cmds.each_with_index do |cmd, idx|
      next if cmd.is_a?(Array) && cmd.any? && cmd.all?(String)

      raise ConfigError,
            "#{path}: 'app.#{section}[#{idx}]' must be a non-empty array of strings, got: #{cmd.inspect}"
    end
  end
  private_class_method :validate_commands!
end
