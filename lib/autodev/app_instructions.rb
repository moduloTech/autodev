# frozen_string_literal: true

# Formats the per-project `app:` config block into a prompt section for danger-claude.
# Each subsection (setup/test/lint/run) is rendered as a list of shell commands that Claude
# must treat as authoritative over CLAUDE.md or skill instructions.
module AppInstructions
  SECTION_HEADERS = {
    'setup' => "Configuration de l'environnement (ces commandes sont prioritaires sur le CLAUDE.md et les skills)",
    'test' => 'Commandes de test (ces commandes sont prioritaires sur le CLAUDE.md et les skills)',
    'lint' => 'Commandes de lint / auto-fix (ces commandes sont prioritaires sur le CLAUDE.md et les skills)'
  }.freeze

  # Returns a prompt section string for the app config, or nil if no app config is present.
  # port_mappings: array of { host_port:, container_port:, command: } from PortAllocator.
  # screenshot_dir: path where Claude should save screenshots (enables screenshot instructions).
  def self.prompt_section(project_config, port_mappings: [], screenshot_dir: nil)
    app = project_config['app']
    return nil unless app.is_a?(Hash) && app.any?

    sections = AppValidator::CMD_SECTIONS.filter_map { |key| format_section(app, key) }
    if app.key?('run')
      sections << format_run_section(app, port_mappings)
      sections << screenshot_instructions(screenshot_dir) if screenshot_dir
    end
    return nil if sections.empty?

    "## Environnement applicatif\n\n#{sections.join("\n\n")}"
  end

  def self.format_section(app, key)
    return nil unless app.key?(key)

    cmds = app[key].map { |cmd| "  - `#{cmd.join(' ')}`" }.join("\n")
    "**#{SECTION_HEADERS[key]}** :\n#{cmds}"
  end
  private_class_method :format_section

  def self.format_run_section(app, port_mappings)
    lines = app['run'].map { |entry| format_run_entry(entry, port_mappings) }
    "**Serveurs applicatifs** (lance-les en background quand tu en as besoin) :\n#{lines.join("\n")}"
  end
  private_class_method :format_run_section

  def self.format_run_entry(entry, port_mappings)
    cmd_str = entry['command'].join(' ')
    mapping = port_mappings.find { |m| m[:container_port] == entry['port'] } if entry['port']
    if mapping
      "  - `#{cmd_str}` — accessible depuis Chrome via `http://localhost:#{mapping[:host_port]}`"
    else
      "  - `#{cmd_str}`"
    end
  end
  private_class_method :format_run_entry

  def self.screenshot_instructions(dir) # rubocop:disable Metrics/MethodLength
    <<~INSTRUCTIONS.strip
      **Captures d'ecran** :
      Apres l'implementation, si tes modifications ont un impact visuel :
        1. Lance le(s) serveur(s) applicatif(s) en background.
        2. Utilise Chrome DevTools pour naviguer vers chaque page modifiee et prendre une capture.
        3. Sauvegarde chaque capture dans `#{dir}/` avec un nom descriptif comme cle (ex: `dashboard_index.png`).
        4. Cree un fichier `#{dir}/index.json` avec le format :
      ```json
      {
        "screenshots": [
          { "key": "dashboard_index", "url": "/dashboard", "description": "Description de la capture", "context": "implementation" }
        ]
      }
      ```
        - `context` vaut `"implementation"` pour les changements initiaux, `"mr_fix"` pour les corrections de review.
        - Si aucune page n'est impactee visuellement, ne cree pas de captures.
    INSTRUCTIONS
  end
  private_class_method :screenshot_instructions
end
