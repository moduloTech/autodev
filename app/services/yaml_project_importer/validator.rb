# frozen_string_literal: true

class YamlProjectImporter
  # Read-only walker. Collects every issue with the YAML into a flat list of
  # error messages so the operator gets the full picture on a single raise —
  # see autodev/docs/autospec.md §H ("Validation pré-write").
  module Validator
    module_function

    def validate(projects_yaml)
      projects_yaml.each_with_index.flat_map { |entry, idx| validate_entry(entry, idx) }
    end

    def validate_entry(entry, idx)
      return ["projects[#{idx}]: entry must be a hash, got #{entry.class}"] unless entry.is_a?(Hash)

      errors = path_errors(entry['path'], idx)
      errors.concat(validate_app_block(entry['app'], idx)) if entry['app']
      errors
    end

    def path_errors(path, idx)
      errors = []
      errors << "projects[#{idx}]: 'path' is required" if path.nil? || path.to_s.strip.empty?
      errors << "projects[#{idx}]: 'path' must look like 'group/project'" if path && !path.include?('/')
      errors
    end

    def validate_app_block(app, idx)
      return ["projects[#{idx}].app: must be a hash, got #{app.class}"] unless app.is_a?(Hash)

      errors = unknown_category_errors(app.keys, idx)
      %w[setup test lint].each { |cat| errors.concat(validate_command_array(app[cat], idx, cat)) }
      errors.concat(validate_run_entries(app['run'], idx)) if app['run']
      errors
    end

    def unknown_category_errors(keys, idx)
      (keys - YamlProjectImporter::APP_COMMAND_CATEGORIES).map do |k|
        "projects[#{idx}].app: unknown category '#{k}' " \
          "(allowed: #{YamlProjectImporter::APP_COMMAND_CATEGORIES.join(', ')})"
      end
    end

    def validate_command_array(entries, idx, cat)
      return [] if entries.nil?
      return ["projects[#{idx}].app.#{cat}: must be an array, got #{entries.class}"] unless entries.is_a?(Array)

      entries.each_with_index.flat_map { |cmd, cmd_idx| command_errors(cmd, idx, cat, cmd_idx) }
    end

    def command_errors(cmd, idx, cat, cmd_idx)
      unless cmd.is_a?(Array)
        return ["projects[#{idx}].app.#{cat}[#{cmd_idx}]: must be an array of strings, got #{cmd.class}"]
      end
      return [] if cmd.all?(String) && cmd.any?

      ["projects[#{idx}].app.#{cat}[#{cmd_idx}]: must be a non-empty array of strings"]
    end

    def validate_run_entries(entries, idx)
      return ["projects[#{idx}].app.run: must be an array, got #{entries.class}"] unless entries.is_a?(Array)

      entries.each_with_index.flat_map { |entry, run_idx| validate_run_entry(entry, idx, run_idx) }
    end

    def validate_run_entry(entry, idx, run_idx)
      return ["projects[#{idx}].app.run[#{run_idx}]: must be a hash, got #{entry.class}"] unless entry.is_a?(Hash)
      return [] if valid_command?(entry['command'])

      ["projects[#{idx}].app.run[#{run_idx}]: 'command' must be a non-empty array of strings"]
    end

    def valid_command?(cmd)
      cmd.is_a?(Array) && cmd.any? && cmd.all?(String)
    end
  end
end
