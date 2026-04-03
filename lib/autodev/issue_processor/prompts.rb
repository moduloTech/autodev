# frozen_string_literal: true

class IssueProcessor
  # Prompt templates for spec checking and question answering.
  module Prompts
    SPEC_CHECK = <<~PROMPT
      Analyse le ticket GitLab suivant et determine sa nature.

      Le contexte complet du ticket est dans le fichier `%s`. Lis-le attentivement.

      ## Instructions de reponse

      Reponds UNIQUEMENT avec un objet JSON valide (sans bloc de code markdown), avec cette structure :
      {
        "type": "implementation" | "question" | "unclear",
        "issues": ["description du probleme 1", "description du probleme 2"]
      }

      - `"type": "implementation"` — specification suffisamment claire. `issues` doit etre vide.
      - `"type": "question"` — pas de modification de code demandee. `issues` doit etre vide.
      - `"type": "unclear"` — specification pas assez precise. Liste les problemes dans `issues`.
      - Sois pragmatique : des details mineurs ne doivent pas bloquer l'implementation.
      - Si le ticket contient des URLs de l'application, extrais le path, cherche la route, lis le code.
    PROMPT

    QUESTION_INVESTIGATION = <<~PROMPT
      Le ticket GitLab suivant pose une question ou demande une investigation sur le code existant.

      Le contexte complet du ticket est dans le fichier `%s`. Lis-le attentivement.

      ## Instructions

      - Explore le codebase pour trouver la reponse.
      - Fournis une reponse claire, factuelle et structuree.
      - Cite les fichiers et lignes pertinents.
      - Si tu ne peux pas repondre avec certitude, indique-le clairement.
      - Reponds en francais.
      - Reponds UNIQUEMENT avec ta reponse (pas de JSON, pas de bloc de code englobant).
    PROMPT

    COMPLEXITY_EVAL = <<~PROMPT
      Analyse le ticket GitLab et determine si l'implementation necessite plusieurs agents en parallele.

      Le contexte complet est dans `%s`. Lis-le attentivement.

      ## Instructions de reponse

      Reponds UNIQUEMENT avec un objet JSON valide :
      { "parallel": true/false, "reason": "explication", "tasks": [{ "name": "...", "description": "...", "scope": "..." }] }

      - `parallel: false` si simple (1-3 fichiers). `tasks` vide.
      - `parallel: true` si plusieurs couches independantes. Max 4 taches.
      - En cas de doute, `parallel: false`.
    PROMPT
  end
end
