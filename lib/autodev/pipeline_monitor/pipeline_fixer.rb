# frozen_string_literal: true

class PipelineMonitor
  # Fixes each failed pipeline job via danger-claude and pushes the result.
  module PipelineFixer
    CATEGORY_INSTRUCTIONS = {
      test: <<~CI,
        Ce job est un job de **tests**. Concentre-toi sur :
        - Les tests en echec : lis les messages d'erreur et les stack traces.
        - Corrige le code source (pas les tests) sauf si les tests sont manifestement incorrects.
        - Si un test echoue a cause d'un changement volontaire de comportement, adapte le test.
      CI
      lint: <<~CI,
        Ce job est un job de **lint/style**. Concentre-toi sur :
        - Les offenses listees dans le log.
        - Corrige uniquement les fichiers signales.
        - Ne change pas la configuration du linter.
      CI
      build: <<~CI
        Ce job est un job de **build/compilation**. Concentre-toi sur :
        - Les erreurs de syntaxe, imports manquants, dependances non resolues.
        - Corrige le code source pour que la compilation/le build passe.
      CI
    }.freeze

    private

    def fix_pipeline_failures(work_dir, job_entries, issue)
      context = fetch_fix_context(work_dir, issue)
      fix_each_job(work_dir, job_entries, issue, context)
      push_fixes(work_dir, job_entries, issue)
    end

    def fetch_fix_context(work_dir, issue)
      {
        skills_line: SkillsInjector.skills_instruction(@all_skills),
        extra: @project_config['extra_prompt'],
        full_context: GitlabHelpers.fetch_full_context(
          @client, @project_path, issue.issue_iid,
          mr_iid: issue.mr_iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir
        )
      }
    end

    def fix_each_job(work_dir, job_entries, issue, context)
      job_entries.each_with_index do |entry, idx|
        category = entry[:category] || :unknown
        if category == :deploy
          log "Skipping deploy job #{idx + 1}/#{job_entries.size}: #{entry[:name]}"
          next
        end
        log "Fixing job #{idx + 1}/#{job_entries.size}: #{entry[:name]} [#{category}] (issue ##{issue.issue_iid})"
        fix_single_job(work_dir, entry, issue, context)
      end
    end

    def fix_single_job(work_dir, entry, issue, context)
      with_context_file(work_dir, issue.branch_name, context[:full_context]) do |context_filename|
        prompt = build_fix_prompt(entry, context_filename, context)
        danger_claude_prompt(work_dir, prompt, label: "-p (pipeline fix: #{entry[:name]})")
      end
      danger_claude_commit(work_dir, label: "-c (pipeline fix: #{entry[:name]})")
    end

    def build_fix_prompt(entry, context_filename, context)
      diagnostic = CATEGORY_INSTRUCTIONS[entry[:category]]
      diagnostic_section = diagnostic ? "\n## Diagnostic\n\n#{diagnostic}" : ''
      extra_section = context[:extra] ? "\n## Instructions supplementaires du projet\n\n#{context[:extra]}" : ''

      fix_prompt_template(entry, context_filename, context[:skills_line], diagnostic_section, extra_section)
    end

    def fix_prompt_template(entry, context_filename, skills, diagnostic, extra)
      <<~PROMPT
        Tu dois corriger le code pour resoudre l'echec du job CI/CD "#{entry[:name]}" (stage: #{entry[:stage]}).
        Le contexte complet du ticket est dans le fichier `#{context_filename}`. Lis-le si necessaire.
        ## Log du job
        Le log complet du job est dans le fichier `#{entry[:log_path]}`. Lis-le pour comprendre l'erreur.
        #{diagnostic}
        ## Instructions
        #{skills}
        - Analyse le log du job en echec.
        - Corrige le code source pour que ce job passe au vert.
        - Respecte les conventions du projet (voir CLAUDE.md si present).
        - Ne modifie que ce qui est necessaire pour corriger l'erreur de ce job.
        - Ne touche pas aux fichiers de configuration CI/CD sauf si c'est la cause directe de l'echec.
        #{extra}
      PROMPT
    end

    def push_fixes(work_dir, job_entries, issue)
      branch = issue.branch_name
      _out, _err, has_commits = run_cmd_status(['git', 'log', "origin/#{branch}..HEAD", '--oneline'], chdir: work_dir)

      if has_commits
        push_branch(work_dir, branch)
        complete_fix_round(issue, job_entries, pushed: true)
      else
        log 'No new commits after pipeline fix, skipping push'
        complete_fix_round(issue, job_entries, pushed: false)
      end
    end

    def complete_fix_round(issue, job_entries, pushed:)
      round = issue.fix_round + 1
      updates = { fix_round: round, pipeline_retrigger_count: 0 }
      updates.merge!(dc_stdout: @dc_stdout, dc_stderr: @dc_stderr) if pushed
      issue.update(updates)
      issue.pipeline_fix_done!
      return unless pushed

      notify_localized(issue.issue_iid, :pipeline_fix_success,
                       mr_url: issue.mr_url, count: job_entries.size, round: round)
      log "Issue ##{issue.issue_iid}: pipeline fix pushed — #{job_entries.size} job(s) (round #{round})"
    end

    def push_branch(work_dir, branch)
      log "Pushing pipeline fixes to #{branch}..."
      _out, _err, push_ok = run_cmd_status(['git', 'push', 'origin', branch], chdir: work_dir)
      return if push_ok

      log 'Push failed, retrying with --force-with-lease...'
      run_cmd(['git', 'push', '--force-with-lease', 'origin', branch], chdir: work_dir)
    end
  end
end
