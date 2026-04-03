# frozen_string_literal: true

require_relative 'rails_sections'

module SkillsInjector
  module Templates
    # Rails conventions skill template with version-specific guidance.
    module RailsConventions
      HEADER = <<~HEADER
        ---
        name: rails-conventions
        description: Ruby on Rails project conventions, patterns, and version-specific guidance. Loaded automatically for Rails implementation tasks.
        ---

        # Rails Conventions
      HEADER

      GENERAL = <<~GENERAL
        ## General Conventions

        - Follow existing code style in the project. Look at similar files before creating new ones.
        - Place business logic in models or service objects (`app/services/`), not controllers.
        - Keep controllers thin: one public action method per route, delegate to models/services.
        - Use `before_action` callbacks for authentication/authorization.
        - Prefer scopes on models for reusable queries.
        - Use I18n for user-facing strings when the project already does.
        - Follow RESTful routing patterns. Avoid custom routes when a standard CRUD action works.
      GENERAL

      module_function

      def build(stack)
        sections = [HEADER, version_line(stack), version_section(stack), GENERAL]
        sections.concat(feature_sections(stack))
        sections.compact.join("\n")
      end

      def version_line(stack)
        versions = []
        versions << "Ruby #{stack[:ruby_version]}" if stack[:ruby_version]
        versions << "Rails #{stack[:rails_version]}" if stack[:rails_version]
        versions.any? ? "This project uses **#{versions.join(' / ')}**." : nil
      end

      def version_section(stack)
        major = Templates.rails_major(stack)
        return nil unless major

        RailsSections::VERSIONS[major <= 4 ? 4 : [major, 8].min]
      end

      def feature_sections(stack)
        sections = []
        sections << RailsSections::DEVISE if stack[:has_devise]
        sections << authorization_section(stack)
        sections << RailsSections::SIDEKIQ[stack[:sidekiq_mode]] if stack[:has_sidekiq]
        sections << RailsSections::API if stack[:api_only]
        sections << RailsSections::RUBOCOP if stack[:has_rubocop]
        sections
      end

      def authorization_section(stack)
        if stack[:has_pundit] then RailsSections::PUNDIT
        elsif stack[:has_cancancan] then RailsSections::CANCANCAN
        end
      end

      private_class_method :version_line, :version_section, :feature_sections, :authorization_section
    end
  end
end
