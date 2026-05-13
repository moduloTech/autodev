# frozen_string_literal: true

class MrFixer
  # Prompt templates for MR discussion fixes.
  # First discussion in a cycle: full context (issue + MR). Followups (resumed
  # session): just the new thread, claude already has the rest in history.
  module FixPrompts
    private

    def build_fix_prompt(context_filename, thread_context, skills_line, extra, app_section)
      <<~PROMPT
        Tu dois corriger le code en reponse a un commentaire de review sur une Merge Request.

        Le contexte complet (issue + discussions MR) est dans le fichier `#{context_filename}`. Lis-le attentivement.

        ## Commentaire de review a traiter

        #{thread_context}

        ## Instructions

        #{skills_line}
        - Le diff ci-dessus montre les lignes exactes concernees par le commentaire.
        - Corrige le code pour repondre au commentaire.
        - Respecte les conventions du projet (voir CLAUDE.md si present).
        - Ne modifie que ce qui est necessaire pour repondre au commentaire.
        - Ne touche pas aux autres parties du code.
        #{"\n#{app_section}" if app_section}
        #{"\n## Instructions supplementaires du projet\n\n#{extra}" if extra}
      PROMPT
    end

    def build_followup_prompt(thread_context)
      <<~PROMPT
        Nouveau commentaire de review a traiter sur la meme Merge Request.

        ## Commentaire de review a traiter

        #{thread_context}

        ## Instructions

        - Corrige le code pour repondre au commentaire.
        - Ne modifie que ce qui est necessaire pour repondre au commentaire.
        - Ne touche pas aux autres parties du code.
      PROMPT
    end
  end
end
