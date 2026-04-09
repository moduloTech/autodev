# frozen_string_literal: true

require_relative 'worktree_merger'
require_relative 'agents'
require_relative 'prompts'

class IssueProcessor
  # Implementation strategies: single, split (code + tests), and parallel agents.
  module Implementer
    include WorktreeMerger
    include Agents

    private

    def implement(work_dir, context, iid)
      @screenshot_dir = ScreenshotUploader.screenshot_dir(@project_path, iid)
      if @project_config['parallel_agents']
        plan = evaluate_complexity(work_dir, context, iid)
        if plan
          implement_parallel(work_dir, context, iid, plan)
          return
        end
        log 'Complexity evaluation returned no plan, falling back'
      end
      implement_fallback(work_dir, context, iid)
    end

    def implement_fallback(work_dir, context, iid)
      if @project_config['split_implementation']
        implement_split(work_dir, context, iid)
      else
        implement_single(work_dir, context, iid)
      end
    end

    def implement_single(work_dir, context, _iid)
      extra = @project_config['extra_prompt']
      app_section = app_section_with_screenshots
      skills_line = SkillsInjector.skills_instruction(@all_skills)

      with_context_file(work_dir, @current_branch_name, context) do |ctx|
        prompt = single_prompt(ctx, skills_line, extra, app_section)
        log 'Running implementation via danger-claude...'
        danger_claude_prompt(work_dir, prompt)
      end
    end

    def single_prompt(context_filename, skills_line, extra, app_section)
      <<~PROMPT
        Tu dois implementer le ticket GitLab suivant.

        Le contexte complet du ticket est dans le fichier `#{context_filename}`. Lis-le attentivement.

        ## Instructions

        #{skills_line}
        - Implemente TOUS les changements decrits dans l'issue.
        - Respecte les conventions du projet (voir CLAUDE.md si present).
        - Ajoute ou modifie les tests si necessaire.
        - Ne modifie que ce qui est necessaire pour resoudre l'issue.
        #{"\n#{app_section}" if app_section}
        #{"\n## Instructions supplementaires du projet\n\n#{extra}" if extra}
      PROMPT
    end

    def evaluate_complexity(work_dir, context, iid)
      out = with_context_file(work_dir, @current_branch_name, context) do |ctx|
        log "Evaluating issue complexity for ##{iid}..."
        danger_claude_prompt(work_dir, format(Prompts::COMPLEXITY_EVAL, ctx), label: '-p (complexity eval)')
      end
      parse_complexity(out, iid)
    rescue JSON::ParserError
      log 'Could not parse complexity evaluation, falling back'
      nil
    end

    def parse_complexity(out, iid)
      json_match = out.match(/\{[^{}]*"parallel"\s*:\s*(true|false).*\}/m)
      return nil unless json_match

      result = JSON.parse(json_match[0])
      return log_simple(iid, result) unless parallel_tasks?(result)

      extract_tasks(result, iid)
    end

    def parallel_tasks?(result)
      result['parallel'] && result['tasks'].is_a?(Array) && result['tasks'].size > 1
    end

    def extract_tasks(result, iid)
      tasks = result['tasks'].map { |t| task_hash(t) }
      log "Issue ##{iid} assessed as complex (#{tasks.size} tasks): #{result['reason']}"
      tasks
    end

    def task_hash(task)
      { name: task['name'].to_s, description: task['description'].to_s, scope: task['scope'].to_s }
    end

    def log_simple(iid, result)
      log "Issue ##{iid} assessed as simple: #{result['reason']}"
      nil
    end

    def app_section_with_screenshots
      AppInstructions.prompt_section(@project_config, port_mappings: @port_mappings || [],
                                                      screenshot_dir: @screenshot_dir)
    end
  end
end
