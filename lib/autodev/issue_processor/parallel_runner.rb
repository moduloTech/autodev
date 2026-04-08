# frozen_string_literal: true

require 'English'
require_relative 'parallel_worktrees'

class IssueProcessor
  # Parallel agent execution for split and multi-agent implementation.
  module ParallelRunner
    include ParallelWorktrees

    private

    def implement_split(work_dir, context, _iid)
      implementer = detect_agent(work_dir, 'implementer')
      test_writer = detect_agent(work_dir, 'test-writer')
      test_worktree = setup_test_worktree(work_dir)

      ctx_file = GitlabHelpers.write_context_file(nil, @current_branch_name, context)
      ctx_name = ctx_file

      prompts = build_split_prompts(ctx_name)
      run_split_agents(work_dir, test_worktree, prompts, implementer, test_writer)
    ensure
      cleanup_test_worktree(test_worktree, work_dir)
    end

    def run_split_agents(work_dir, test_worktree, prompts, implementer, test_writer)
      log 'Running implementer + test-writer in parallel...'
      results = run_two_threads(
        -> { danger_claude_prompt(work_dir, prompts[:code], agent: implementer, label: '-p (implement code)') },
        -> { danger_claude_prompt(test_worktree, prompts[:test], agent: test_writer, label: '-p (write tests)') }
      )
      raise results[:code_error] if results[:code_error]

      handle_test_results(results, test_worktree, work_dir)
    end

    def handle_test_results(results, test_worktree, work_dir)
      if results[:test_error]
        log_error("Test-writer failed: #{results[:test_error].message}")
      else
        merge_test_files(test_worktree, work_dir)
      end
    end

    def run_two_threads(code_fn, test_fn)
      results = { code_error: nil, test_error: nil }
      threads = [
        Thread.new { code_fn.call rescue results[:code_error] = $ERROR_INFO }, # rubocop:disable Style/RescueModifier
        Thread.new { test_fn.call rescue results[:test_error] = $ERROR_INFO } # rubocop:disable Style/RescueModifier
      ]
      threads.each(&:join)
      results
    end

    def build_split_prompts(context_filename)
      extra = @project_config['extra_prompt']
      app_section = AppInstructions.prompt_section(@project_config)
      skills = SkillsInjector.skills_instruction(@all_skills)
      extra_section = extra ? "\n## Instructions supplementaires du projet\n\n#{extra}" : ''
      app_block = app_section ? "\n#{app_section}" : ''
      base = "Le contexte est dans `#{context_filename}`. Lis-le attentivement.\n\n## Instructions\n\n#{skills}"

      { code: code_prompt(base, app_block, extra_section), test: test_prompt(base, app_block, extra_section) }
    end

    def code_prompt(base, app_block, extra_section)
      "Tu dois implementer le ticket GitLab suivant.\n\n#{base}\n" \
        "- Implemente TOUS les changements.\n- N'ecris PAS de tests.\n" \
        "- Ne modifie que ce qui est necessaire.#{app_block}#{extra_section}\n"
    end

    def test_prompt(base, app_block, extra_section)
      "Tu dois ecrire les tests pour le ticket GitLab suivant.\n\n#{base}\n" \
        "- Ecris les tests en te basant sur la specification.\n" \
        "- Ne modifie PAS le code source.\n- Couvre les cas nominaux et limites.#{app_block}#{extra_section}\n"
    end

    def implement_parallel(work_dir, context, iid, tasks)
      skills = SkillsInjector.skills_instruction(@all_skills)
      log "Running #{tasks.size} parallel agents for issue ##{iid}..."

      worktrees = setup_parallel_worktrees(work_dir, tasks, context)
      errors = run_parallel_agents(worktrees, tasks, skills)
      worktrees.each { |wt| merge_worktree_files(wt[:path], work_dir, wt[:task][:name]) }

      raise_if_all_failed(errors, tasks)
    ensure
      cleanup_worktrees(worktrees || [], work_dir)
    end

    def run_parallel_agents(worktrees, tasks, skills)
      errors = []
      threads = worktrees.each_with_index.map do |wt, idx|
        Thread.new { run_single_parallel_agent(wt, tasks[idx], tasks.size, skills, errors) }
      end
      threads.each(&:join)
      errors
    end

    def run_single_parallel_agent(worktree, task, total, skills, errors)
      ctx_name = GitlabHelpers.context_file_path(@current_branch_name)
      prompt = parallel_prompt(task, ctx_name, skills)
      log "Agent #{task[:name]} (#{total} total)"
      danger_claude_prompt(worktree[:path], prompt, label: "-p (parallel: #{task[:name]})")
    rescue StandardError => e
      errors << { task: task[:name], error: e }
    end

    def parallel_prompt(task, context_filename, skills)
      extra = @project_config['extra_prompt']
      app_section = AppInstructions.prompt_section(@project_config)
      <<~PROMPT
        Tu dois implementer UNE PARTIE d'un ticket GitLab.

        Le contexte complet est dans `#{context_filename}`. Lis-le attentivement.

        ## Ta tache

        **#{task[:name]}** : #{task[:description]}
        Scope : `#{task[:scope]}`

        ## Instructions

        #{skills}
        - N'implemente QUE ta tache. Ne touche PAS aux fichiers hors de ton scope.
        - Respecte les conventions du projet.
        #{"\n#{app_section}" if app_section}
        #{"\n## Instructions supplementaires\n\n#{extra}" if extra}
      PROMPT
    end
  end
end
