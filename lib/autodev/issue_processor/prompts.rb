# frozen_string_literal: true

class IssueProcessor
  # Prompt templates for spec checking and question answering.
  module Prompts
    # The blocking criteria are explicit (Autodev #122). The old prompt carried
    # one rule about blocking, and it pushed the other way ("des details mineurs
    # ne doivent pas bloquer"): POWERPANNE#14746 was cleared in 23 seconds on
    # 28/08/2026 although the answer to autodev's own question had turned a
    # monthly e-mail into a screen nobody had placed, scoped or given an output.
    # Pragmatism stays — for the details that really are minor.
    SPEC_CHECK = <<~PROMPT
      Analyse le ticket GitLab suivant et determine sa nature.

      Le contexte complet du ticket est dans le fichier `%s`. Lis-le attentivement, commentaires compris :
      ils sont posterieurs a la description et peuvent la modifier.

      ## Instructions de reponse

      Reponds UNIQUEMENT avec un objet JSON valide (sans bloc de code markdown), avec cette structure :
      {
        "type": "implementation" | "question" | "unclear",
        "issues": ["description du probleme 1", "description du probleme 2"]
      }

      - `"type": "implementation"` — specification suffisamment claire. `issues` doit etre vide.
      - `"type": "question"` — pas de modification de code demandee. `issues` doit etre vide.
      - `"type": "unclear"` — specification pas assez precise. Liste les problemes dans `issues`.

      ## Ce qui bloque : reponds "unclear"

      Chacun de ces cas suffit, meme si le reste du ticket est precis :

      1. **La description contredit une reponse donnee plus tard dans les commentaires.** La description dit une
         chose, un commentaire posterieur en dit une autre, et rien ne tranche laquelle fait foi.
      2. **Une decision est prise, mais ce qu'elle implique n'est pas decrit.** Pour toute decision prise dans la
         description ou dans un commentaire, verifie que le ticket dit : quel ecran ou quel emplacement dans
         l'application ; qui y a acces ; quelle sortie (fichier telecharge, email et son destinataire, affichage) ;
         et si cela remplace l'existant ou s'y ajoute. Un de ces points absent et impossible a deduire du code,
         c'est un probleme a lister.
      3. **Une reponse a une clarification precedente change la nature de la demande** (par exemple un envoi
         automatique devient un ecran de selection, un export devient une fonctionnalite). Ne conclus alors
         `"implementation"` que si ce qu'implique la nouvelle demande est decrit, au sens du point 2.

      Pour chaque probleme, ecris dans `issues` une question precise que le demandeur peut trancher, en citant ce
      qui se contredit ou ce qui manque.

      ## Ce qui ne bloque pas

      - Sois pragmatique : les details vraiment mineurs (libelles, ordre des colonnes, mise en forme, valeurs par
        defaut evidentes, choix techniques internes) ne doivent pas bloquer l'implementation.
      - Ne demande pas ce que le code permet de trancher. Si le ticket contient des URLs de l'application, extrais
        le path, cherche la route, lis le code.
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
