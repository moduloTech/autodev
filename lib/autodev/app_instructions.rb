# frozen_string_literal: true

# Formats the per-project `app:` config block into a prompt section for danger-claude.
# Each subsection (setup/test/lint) is rendered as a list of shell commands that Claude
# must treat as authoritative over CLAUDE.md or skill instructions.
module AppInstructions
  SECTION_HEADERS = {
    'setup' => "Configuration de l'environnement (ces commandes sont prioritaires sur le CLAUDE.md et les skills)",
    'test' => 'Commandes de test (ces commandes sont prioritaires sur le CLAUDE.md et les skills)',
    'lint' => 'Commandes de lint / auto-fix (ces commandes sont prioritaires sur le CLAUDE.md et les skills)'
  }.freeze

  # Returns a prompt section string for the app config, or nil if no app config is present.
  def self.prompt_section(project_config)
    app = project_config['app']
    return nil unless app.is_a?(Hash) && app.any?

    sections = AppValidator::SECTIONS.filter_map { |key| format_section(app, key) }
    return nil if sections.empty?

    "## Environnement applicatif\n\n#{sections.join("\n\n")}"
  end

  def self.format_section(app, key)
    return nil unless app.key?(key)

    cmds = app[key].map { |cmd| "  - `#{cmd.join(' ')}`" }.join("\n")
    "**#{SECTION_HEADERS[key]}** :\n#{cmds}"
  end
  private_class_method :format_section
end
