# frozen_string_literal: true

require 'English'
class IssueProcessor
  # Parallel agent execution for split and multi-agent implementation.
  module ParallelRunner
    private

    def implement_split(work_dir, context, _iid)
      implementer = detect_agent(work_dir, 'implementer')
      test_writer = detect_agent(work_dir, 'test-writer')
      test_worktree = setup_test_worktree(work_dir)

      ctx_file = GitlabHelpers.write_context_file(work_dir, @current_branch_name, context)
      GitlabHelpers.write_context_file(test_worktree, @current_branch_name, context)
      ctx_name = File.basename(ctx_file)

      prompts = build_split_prompts(ctx_name)
      run_split_agents(work_dir, test_worktree, prompts, implementer, test_writer)
    ensure
      cleanup_test_worktree(test_worktree, work_dir)
    end

    def setup_test_worktree(work_dir)
      test_wt = "#{work_dir}_tests"
      run_cmd(['git', 'worktree', 'add', test_wt, 'HEAD'], chdir: work_dir)
      SkillsInjector.inject(test_wt, logger: @logger, project_path: @project_path)
      copy_agents(work_dir, test_wt)
      test_wt
    end

    def run_split_agents(work_dir, test_worktree, prompts, implementer, test_writer)
      log 'Running implementer + test-writer in parallel...'
      results = run_two_threads(
        -> { danger_claude_prompt(work_dir, prompts[:code], agent: implementer, label: '-p (implement code)') },
        -> { danger_claude_prompt(test_worktree, prompts[:test], agent: test_writer, label: '-p (write tests)') }
      )
      raise results[:code_error] if results[:code_error]

      if results[:test_error]
        log_error("Test-writer failed: #{results[:test_error].message}")
      else
        merge_test_files(
          test_worktree, work_dir
        )
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
      skills = SkillsInjector.skills_instruction(@all_skills)
      extra_section = extra ? "\n## Instructions supplementaires du projet\n\n#{extra}" : ''
      base = "Le contexte est dans `#{context_filename}`. Lis-le attentivement.\n\n## Instructions\n\n#{skills}"

      {
        code: "Tu dois implementer le ticket GitLab suivant.\n\n#{base}\n" \
              "- Implemente TOUS les changements.\n- N'ecris PAS de tests.\n" \
              "- Ne modifie que ce qui est necessaire.#{extra_section}\n",
        test: "Tu dois ecrire les tests pour le ticket GitLab suivant.\n\n#{base}\n" \
              "- Ecris les tests en te basant sur la specification.\n" \
              "- Ne modifie PAS le code source.\n- Couvre les cas nominaux et limites.#{extra_section}\n"
      }
    end

    def implement_parallel(work_dir, context, iid, tasks)
      skills = SkillsInjector.skills_instruction(@all_skills)
      log "Running #{tasks.size} parallel agents for issue ##{iid}..."

      worktrees = setup_parallel_worktrees(work_dir, tasks, context)
      errors = run_parallel_agents(work_dir, worktrees, tasks, skills)
      worktrees.each { |wt| merge_worktree_files(wt[:path], work_dir, wt[:task][:name]) }

      raise_if_all_failed(errors, tasks)
    ensure
      cleanup_worktrees(worktrees || [], work_dir)
    end

    def setup_parallel_worktrees(work_dir, tasks, context)
      tasks.each_with_index.map do |task, idx|
        wt_path = "#{work_dir}_task_#{idx}"
        run_cmd(['git', 'worktree', 'add', wt_path, 'HEAD'], chdir: work_dir)
        SkillsInjector.inject(wt_path, logger: @logger, project_path: @project_path)
        copy_agents(work_dir, wt_path)
        GitlabHelpers.write_context_file(wt_path, @current_branch_name, context)
        { path: wt_path, task: task }
      end
    end

    def run_parallel_agents(_work_dir, worktrees, tasks, skills)
      errors = []
      threads = worktrees.each_with_index.map do |wt, idx|
        Thread.new do
          ctx_name = File.basename(Dir.glob(File.join(wt[:path], '.claude', 'context', '*')).first || '')
          prompt = parallel_prompt(tasks[idx], ctx_name, skills)
          log "Agent #{idx + 1}/#{tasks.size}: #{tasks[idx][:name]}"
          danger_claude_prompt(wt[:path], prompt, label: "-p (parallel: #{tasks[idx][:name]})")
        rescue StandardError => e
          errors << { task: tasks[idx][:name], error: e }
        end
      end
      threads.each(&:join)
      errors
    end

    def parallel_prompt(task, context_filename, skills)
      extra = @project_config['extra_prompt']
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
        #{"\n## Instructions supplementaires\n\n#{extra}" if extra}
      PROMPT
    end

    def copy_agents(src_dir, dst_dir)
      agents_src = File.join(src_dir, '.claude', 'agents')
      return unless Dir.exist?(agents_src)

      agents_dst = File.join(dst_dir, '.claude', 'agents')
      FileUtils.mkdir_p(agents_dst)
      FileUtils.cp_r(Dir.glob(File.join(agents_src, '*')), agents_dst)
    end

    def raise_if_all_failed(errors, tasks)
      return unless errors.size == tasks.size

      raise ImplementationError, "All parallel agents failed: #{errors.map do |e|
        "#{e[:task]}: #{e[:error].message}"
      end.join('; ')}"
    end

    def cleanup_test_worktree(test_worktree, work_dir)
      return unless test_worktree

      GitlabHelpers.cleanup_context_file(test_worktree, @current_branch_name)
      return unless Dir.exist?(test_worktree)

      run_cmd_status(['git', 'worktree', 'remove', '--force', test_worktree], chdir: work_dir)
      FileUtils.rm_rf(test_worktree)
    end

    def cleanup_worktrees(worktrees, work_dir)
      worktrees.each do |wt|
        GitlabHelpers.cleanup_context_file(wt[:path], @current_branch_name) if wt[:path]
        next unless Dir.exist?(wt[:path])

        run_cmd_status(['git', 'worktree', 'remove', '--force', wt[:path]], chdir: work_dir)
        FileUtils.rm_rf(wt[:path])
      end
    end
  end
end
