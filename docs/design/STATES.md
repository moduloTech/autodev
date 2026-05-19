# Autodev — Vocabulaire d'états

Cette table fait le pont entre les états techniques (machine d'état AASM côté Ruby) et les formulations affichées au support client.

## Principe

Le support client n'a **pas besoin** de connaître les détails techniques. Chaque état technique est traduit en :
- une **étiquette courte** (pour les pastilles)
- un **ton de couleur** (working / ok / warn / err / muted)
- une **description longue** (tooltip ou panneau d'aide)

## Table de correspondance

| État technique | Étiquette FR | Ton | Description |
|---|---|---|---|
| `pending` | En attente | muted | Demande reçue, Autodev démarrera dès qu'un agent est disponible. |
| `cloning` | Préparation | working | Récupération du code source. |
| `checking_spec` | Lecture du besoin | working | Analyse de la description et du contexte du projet. |
| `implementing` | En train de coder | working | Modifications en cours dans le code. |
| `committing` | Sauvegarde | working | Validation des modifications dans Git. |
| `pushing` | Envoi sur GitLab | working | Pousse les modifications sur le serveur. |
| `creating_mr` | Création de la MR | working | Ouverture de la demande de fusion. |
| `reviewing` | Auto-revue | working | Autodev relit son propre travail. |
| `checking_pipeline` | Vérifications | working | Tests automatiques en cours. |
| `answering_question` | Réponse en cours | working | Autodev répond à une question d'un développeur. |
| `running_post_completion` | Post-traitement | working | Actions finales (notifications, mise à jour des tickets liés). |
| `fixing_discussions` | Corrections demandées | working | Traitement des commentaires de revue. |
| `fixing_pipeline` | Tests à corriger | working | Tentative de correction des tests qui échouent. |
| `needs_clarification` | Question en attente | warn | Autodev attend une réponse pour continuer. |
| `done` | Livré | ok | Demande terminée. |
| `error` | Échec | err | Blocage qui demande une intervention humaine. |

## Tons utilisés

| Ton | Usage | Token de fond | Token de texte |
|---|---|---|---|
| working | Travail en cours par Autodev | `--work-bg` | `--work-fg` |
| ok | Succès, terminé | `--ok-bg` | `--ok-fg` |
| warn | Attention requise | `--warn-bg` | `--warn-fg` |
| err | Erreur, action humaine requise | `--err-bg` | `--err-fg` |
| muted | Neutre, en attente | `--paper-2` | `--text-muted` |

## Mots à éviter

- ❌ "Pipeline" → ✅ "Vérifications automatiques"
- ❌ "MR" / "Merge request" → ✅ "Demande de fusion"
- ❌ "Commit" → ✅ "Sauvegarde"
- ❌ "Branch" → ✅ "Branche" (acceptable, on est en FR)
- ❌ "Issue" → ✅ "Demande" (sauf dans le contexte technique GitLab)
