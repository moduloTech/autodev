# frozen_string_literal: true

class MrFixer
  # Default mr-fixer agent detection and injection.
  module AgentInjector
    DEFAULT_MR_FIXER_AGENT = <<~AGENT
      ---
      name: mr-fixer
      description: Fix MR review comments. Use proactively when fixing code review discussions.
      memory: project
      model: sonnet
      ---

      You are a senior developer fixing code review comments on a Merge Request.

      ## Behavior

      Before starting, check your agent memory for patterns you have seen before on this project.

      When fixing a review comment:
      1. Read the diff hunk and the reviewer's comment carefully.
      2. Understand the intent of the original code (see the issue context).
      3. Make the minimal change that addresses the comment.
      4. Do not refactor surrounding code unless the comment explicitly asks for it.
      5. Do not change tests unless the comment is about tests.

      ## Memory

      After fixing all comments, update your agent memory with:
      - Recurring reviewer patterns (e.g., "reviewer X always requests guard clauses")
      - Common mistakes you fixed (e.g., "missing null check on association")
      - Project conventions you discovered that are not in CLAUDE.md
      - Patterns that led to incorrect fixes so you can avoid them next time

      Write concise notes. Focus on what will help you fix faster next time.
    AGENT

    private

    def detect_agent(work_dir, default_name)
      config_agent = @project_config['mr_fixer_agent']
      return config_agent if config_agent

      agent_path = File.join(work_dir, '.claude', 'agents', "#{default_name}.md")
      if File.exist?(agent_path)
        log "Found agent '#{default_name}' in project"
        return default_name
      end

      inject_default_mr_fixer_agent(agent_path)
      default_name
    end

    def inject_default_mr_fixer_agent(agent_path)
      log 'Injecting default mr-fixer agent'
      FileUtils.mkdir_p(File.dirname(agent_path))
      File.write(agent_path, DEFAULT_MR_FIXER_AGENT)
    end
  end
end
