# frozen_string_literal: true

require_relative 'templates/code_conventions'
require_relative 'templates/rails_conventions'
require_relative 'templates/test_patterns'
require_relative 'templates/database_patterns'

module SkillsInjector
  # Generates skill file content based on detected stack.
  module Templates
    def self.rails_major(stack)
      version = stack[:rails_version]
      return nil unless version

      version.split('.').first.to_i
    end

    module_function

    def code_conventions_skill(_stack = nil)
      CodeConventions.build
    end

    def rails_conventions_skill(stack = nil)
      RailsConventions.build(stack || {})
    end

    def test_patterns_skill(stack = nil)
      TestPatterns.build(stack || {})
    end

    def database_patterns_skill(stack = nil)
      DatabasePatterns.build(stack || {})
    end
  end
end
