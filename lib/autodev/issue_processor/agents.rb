# frozen_string_literal: true

class IssueProcessor
  # Agent detection and default agent injection.
  module Agents
    IMPLEMENTER_AGENT = <<~AGENT
      ---
      name: implementer
      description: Implement code changes from issue specifications. Use proactively for implementation tasks.
      model: sonnet
      ---

      You are a senior developer implementing code changes from a GitLab issue specification.

      Focus exclusively on production code. Do NOT write or modify tests — a separate agent handles testing.

      When implementing:
      1. Read the issue context and CLAUDE.md carefully.
      2. Identify all files that need changes.
      3. Make minimal, focused changes that satisfy the requirements.
      4. Follow existing code patterns and conventions.
    AGENT

    TEST_WRITER_AGENT = <<~AGENT
      ---
      name: test-writer
      description: Write tests from issue specifications. Use proactively for testing tasks.
      model: sonnet
      ---

      You are a senior developer writing tests from an issue specification.
      Another agent is implementing the code in parallel — you do NOT have access to it.

      Focus exclusively on test files. Do NOT modify production code.

      When writing tests:
      1. Read the issue specification carefully to understand expected behavior.
      2. Check existing tests for patterns, helpers, factories, and conventions.
      3. Write tests that verify the specified behavior: nominal cases and edge cases.
      4. Follow the project's test framework and style exactly.
      5. Use descriptive test names that reflect the specification, not the implementation.
    AGENT

    private

    def detect_agent(work_dir, agent_name)
      config_key = "#{agent_name.tr('-', '_')}_agent"
      config_agent = @project_config[config_key]
      return config_agent if config_agent

      agent_path = File.join(work_dir, '.claude', 'agents', "#{agent_name}.md")
      if File.exist?(agent_path)
        log "Found agent '#{agent_name}' in project"
        return agent_name
      end

      inject_default_agent(agent_name, agent_path)
    end

    def inject_default_agent(agent_name, agent_path)
      template = agent_template(agent_name)
      return nil unless template

      log "Injecting default '#{agent_name}' agent"
      FileUtils.mkdir_p(File.dirname(agent_path))
      File.write(agent_path, template)
      agent_name
    end

    def agent_template(agent_name)
      case agent_name
      when 'implementer' then IMPLEMENTER_AGENT
      when 'test-writer' then TEST_WRITER_AGENT
      end
    end
  end
end
