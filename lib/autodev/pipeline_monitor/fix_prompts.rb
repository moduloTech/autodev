# frozen_string_literal: true

class PipelineMonitor
  # Prompt templates for pipeline fix via danger-claude.
  module FixPrompts
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
  end
end
