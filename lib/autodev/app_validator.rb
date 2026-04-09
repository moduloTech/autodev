# frozen_string_literal: true

# Validates the per-project `app:` configuration block (setup/test/lint/run).
module AppValidator
  CMD_SECTIONS = %w[setup test lint].freeze
  ALL_SECTIONS = (CMD_SECTIONS + %w[run]).freeze

  def self.validate!(project_config, path)
    return unless project_config.key?('app')

    app = project_config['app']
    validate_type!(app, path)
    validate_keys!(app, path)
    CMD_SECTIONS.each { |section| validate_section!(app, section, path) }
    validate_run!(app, path)
  end

  def self.validate_type!(app, path)
    return if app.is_a?(Hash)

    raise ConfigError, "#{path}: 'app' must be a mapping with optional keys: #{ALL_SECTIONS.join(', ')}."
  end
  private_class_method :validate_type!

  def self.validate_keys!(app, path)
    unknown = app.keys - ALL_SECTIONS
    return if unknown.empty?

    raise ConfigError, "#{path}: unknown app keys: #{unknown.join(', ')}. Allowed: #{ALL_SECTIONS.join(', ')}."
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

  def self.validate_run!(app, path)
    return unless app.key?('run')

    entries = app['run']
    unless entries.is_a?(Array) && entries.any?
      raise ConfigError, "#{path}: 'app.run' must be a non-empty array of entries."
    end

    entries.each_with_index { |entry, idx| validate_run_entry!(entry, idx, path) }
  end
  private_class_method :validate_run!

  def self.validate_run_entry!(entry, idx, path)
    unless entry.is_a?(Hash)
      raise ConfigError, "#{path}: 'app.run[#{idx}]' must be a mapping with 'command' and optional 'port'."
    end

    validate_run_command!(entry, idx, path)
    validate_run_port!(entry, idx, path)
  end
  private_class_method :validate_run_entry!

  def self.validate_run_command!(entry, idx, path)
    cmd = entry['command']
    return if cmd.is_a?(Array) && cmd.any? && cmd.all?(String)

    raise ConfigError,
          "#{path}: 'app.run[#{idx}].command' must be a non-empty array of strings, got: #{cmd.inspect}"
  end
  private_class_method :validate_run_command!

  def self.validate_run_port!(entry, idx, path)
    return unless entry.key?('port')

    port = entry['port']
    return if port.is_a?(Integer) && port.positive? && port <= 65_535

    raise ConfigError,
          "#{path}: 'app.run[#{idx}].port' must be an integer between 1 and 65535, got: #{port.inspect}"
  end
  private_class_method :validate_run_port!
end
