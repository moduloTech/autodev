---
title: "Autodev — Guide technique"
subtitle: "Routes admin, configuration projet, CLI, machine à états"
author: "Modulotech"
date: 2026-06-11
lang: fr
documentclass: article
papersize: a4
geometry: margin=2cm
fontsize: 11pt
toc: true
toc-depth: 2
numbersections: true
colorlinks: true
linkcolor: blue
urlcolor: blue
---

\newpage

# À qui s'adresse ce document

Ce guide complète le [guide utilisateur](autodev-functional-usage.md) en couvrant tout ce qui n'a pas sa place dans une doc destinée aux non-techniciens : routes admin, configuration des projets dans `~/.autodev/config.yml`, ligne de commande, machine à états AASM, et catalogue des erreurs.

Public visé : administrateurs de la plateforme Autodev, développeurs intervenant sur le code Autodev, ops chargés de maintenir l'instance en production.

L'instance prod tourne sur `https://autodev.netbird.modulotech.fr`, derrière le SSO Microsoft 365 (Entra ID via Devise + OmniAuth, formulaire CSRF-protégé sur `/sign_in`). Architecture : Rails 8.1 + Solid Queue, SQLite multi-DB (`~/.autodev/autodev.db` + `~/.autodev/autodev_queue.db`), supervisor `bin/autodev` qui fork `bin/rails server` + `bin/jobs start`.

\newpage

# Routes du dashboard

| Route | Contrôleur | Description |
|---|---|---|
| `/` | `DashboardController#show` | KPIs, listes actives, sparkline, banderole erreurs |
| `/issues` | `IssuesController#index` | Liste paginée + filtrable (`?tab=`, `?q=`, `?from=`, `?to=`) |
| `/issues/:id` | `IssuesController#show` | Détail + activity events (200 derniers) |
| `/issues/:id.json` | `IssuesController#show` | Mêmes données, format JSON |
| `/issues/:id/reset` (POST) | `IssuesController#reset` | Reset brut (raw SQL, pas une transition AASM) |
| `/issues/:id/transition` (POST) | `IssuesController#transition` | Déclenche un événement AASM (`?event=...`) |
| `/errors` | `ErrorsController#index` | Issues en `error` + `needs_clarification` + `post_completion_error IS NOT NULL` |
| `/projects` | `ProjectsController#index` | Union des projets YAML + projets ayant des rows |
| `/projects/:slug` | `ProjectsController#show` | Slug = `group/sub/name` encodé en `group__sub__name` |
| `/list/:status` | `ListController#show` | Filtre par status exact (cap 500) |
| `/stream` | `StreamController#show` | Server-Sent Events, `ActionController::Live` |
| `/locale/:lang` | `LocaleController#update` | Set le cookie `locale`, redirige sur `back` |
| `/users/auth/entra_id` (+ callback) | Devise | OmniAuth Microsoft 365 |
| `/sign_in` | `SignInController#new` | Page d'atterrissage avec form POST CSRF |
| `/admin/users` | `Admin::UsersController#index` | Audit users + memberships (admin only) |
| `/admin/jobs` | Mission Control | Inspecteur Solid Queue (admin only) |

Toutes les routes hors `/sign_in` et SSO sont gatées par le `before_action :authenticate_user!` global (PR3 du chantier *users-rollout*). Les routes `/admin/*` ajoutent un check `current_user&.admin?` au-dessus.

Pas de chrome custom sur `/admin/jobs` — c'est l'UI fournie par la gem `mission_control-jobs`.

## Comportement temps réel

- `/stream` est une long-lived SSE. Tout `ActivityEvent` créé est publié sur `Web::EventBus` (in-process pub/sub, backpressure drop à 100), puis transformé en Turbo Stream HTML envoyé sur la connexion ouverte.
- Le layout Phlex ouvre une `EventSource('/stream')` au `turbo:load`. Désactivé sous `navigator.webdriver` pour ne pas bloquer les outils d'automation qui attendent `networkidle`.

\newpage

# Admin — Utilisateurs

URL `/admin/users`. Audit lecture seule de la table `users` et de la table `project_memberships`. Accès restreint aux comptes avec `admin = true`.

![Page admin — un utilisateur, deux memberships, owner.](screenshots/07-admin-users.png)

Colonnes :

- **Email** — identifiant SSO ;
- **Name** — nom complet remonté par Entra ID ;
- **Admin** — `users.admin = true` (donne accès à `/admin/*`) ;
- **GitLab** — `users.gitlab_username` (résolu par la synchro) ;
- **Status** — `active` ou `inactive` (rebasculé selon les memberships GitLab) ;
- **Memberships** — entrées de `project_memberships`, rôle `owner` ou `contributor`.

Les memberships sont dérivés d'une synchro GitLab (commande CLI `--sync-memberships`). Pas d'édition manuelle depuis l'UI : la sync GitLab fait foi. Pour bootstrapper le premier admin, utiliser `autodev --seed-admin EMAIL`.

\newpage

# Mission Control — Jobs

URL `/admin/jobs`. UI de la gem `mission_control-jobs` montée sur l'app Rails, branchée sur Solid Queue.

![Mission Control — vue queues.](screenshots/10-mission-control.png)

Sections :

- **Queues** — `default` et `solid_queue_recurring`.
- **Failed jobs** — devrait toujours être à 0. Un job en échec ici = un bug à diagnostiquer.
- **In Progress jobs** — les jobs en cours d'exécution.
- **Blocked jobs** — concurrence sérialisée (cf. `IssueProcessJob#limits_concurrency`).
- **Scheduled jobs** — jobs programmés via `enqueue_at`.
- **Finished jobs** — historique (5K+ en prod).
- **Workers** — les workers Solid Queue actifs (forks de `bin/jobs start`).
- **Recurring tasks** — `AutodevPollJob` programmé selon `config/recurring.yml`.

À vérifier en cas de souci :

1. Le worker Solid Queue tourne (sinon les `AutodevPollJob` ne s'enquilleraient pas).
2. La tâche récurrente `AutodevPollJob` est bien programmée à l'intervalle attendu.
3. Aucun job n'est resté bloqué en *In Progress* après un crash supervisor.
4. La file *Failed jobs* est vide.

Auth : `current_user&.admin?` requis (cf. `config/initializers/mission_control.rb`).

\newpage

# Configuration d'un projet

Toute la config projet vit dans `~/.autodev/config.yml`, sous le bloc `projects:`. Chaque entrée porte le `path` GitLab et un sous-bloc optionnel `app:` qui injecte des instructions d'environnement dans les prompts `danger-claude` (priorité sur les `CLAUDE.md` du projet et sur les skills).

Exemple complet :

```yaml
projects:
  - path: modulosource/powerpanne/powerpanne/core
    app:
      setup:
        - ["bundle", "install"]
        - ["yarn", "install"]
      test:
        - ["bin/test"]
      lint:
        - ["bundle", "exec", "rubocop", "-A"]
      run:
        - command: ["bin/rails", "s"]
          port: 3000
        - command: ["bin/vite", "dev"]
      post_completion:
        - ["bin/notify_teams.sh"]
      additional_prompt: |
        Quand tu modifies un fichier de migration, ajoute toujours
        un test de la rollback.
```

## Blocs disponibles

| Bloc | Effet |
|---|---|
| `setup` | Commandes pour installer les dépendances. Lancées avant chaque cycle. |
| `test` | Comment lancer la suite de tests. Utilisé par le pipeline fixer. |
| `lint` | Comment auto-fixer (`rubocop -A`, `eslint --fix`, etc.). |
| `run` | Serveurs à lancer pour les captures d'écran. Si au moins une commande a un `port`, Chrome DevTools est auto-activé pour permettre à `danger-claude` de screenshoter les pages impactées et de les uploader en commentaire d'issue. |
| `post_completion` | Hook(s) lancés après livraison (sur désassignation, voir cycle de vie). |
| `additional_prompt` | Texte ajouté à tous les prompts `danger-claude` pour ce projet. |

## Synchronisation GitLab

La table `projects` est alimentée par le poller (chaque nouveau ticket crée la row si elle manque). Les memberships sont alimentés par `autodev --sync-memberships` (qui doit être lancée manuellement ou via une tâche planifiée).

Attention : un `--sync-memberships` lancé sur une base `projects` vide désactive silencieusement tous les users. Toujours vérifier `Project.count > 0` avant de lancer la sync.

\newpage

# Outils en ligne de commande

Le binaire `autodev` est à la fois le supervisor (par défaut, démarre Rails + Solid Queue) et une CLI qui lit/mute la base SQLite directement (sans passer par le worker).

## Supervisor

| Commande | Effet |
|---|---|
| `autodev` | Lance le supervisor (Rails + worker Solid Queue), foreground. |
| `brew services start autodev` | Idem mais via launchd, logs dans `~/.autodev/log/`. |
| `autodev -c PATH` | Utilise un fichier de config alternatif. |
| `autodev -n N` | Force le nombre de workers Solid Queue (`AUTODEV_MAX_WORKERS`). |
| `autodev -i SECONDS` | Force l'intervalle de poll (`AUTODEV_POLL_INTERVAL`). |

## CLI directe (lit/écrit la DB et exit)

| Commande | Effet |
|---|---|
| `autodev --status` | Tableau ASCII des demandes suivies (non `done`). |
| `autodev --status --all` | Inclut les demandes `done`. |
| `autodev --errors` | Détail des demandes en `error`. |
| `autodev --errors IID` | Détail d'une demande spécifique. |
| `autodev --reset` | Reset toutes les demandes `error` vers `pending`. |
| `autodev --reset IID` | Reset une demande. |
| `autodev --seed-admin EMAIL` | Crée un compte admin local (bootstrap initial). |
| `autodev --sync-memberships` | Synchronise `project_memberships` depuis GitLab. |
| `autodev --link-user EMAIL,GITLAB_USERNAME` | Override manuel du `gitlab_username` d'un user. |
| `autodev --version` | Version courante. |

## Polling forcé

```bash
bin/rails runner 'AutodevPollJob.perform_now'
```

Exécute un cycle de poll complet de façon synchrone, en réutilisant le code du job. Utile pour debugger sans attendre le tick suivant.

## Variables d'environnement

| Variable | Effet |
|---|---|
| `GITLAB_API_TOKEN` | Token GitLab personal (requis). |
| `GITLAB_URL` | Override de l'URL GitLab (défaut `https://gitlab.com`). |
| `AUTODEV_HOME` | Racine de l'état sur disque (défaut `~/.autodev`). |
| `AUTODEV_DB` | Path SQLite primaire. |
| `AUTODEV_QUEUE_DB` | Path SQLite Solid Queue. |
| `AUTODEV_MAX_WORKERS` | Threads Solid Queue (défaut 3). |
| `AUTODEV_POLL_INTERVAL` | Intervalle de poll en secondes (défaut 300). |

\newpage

# Machine à états (AASM)

Le modèle `Issue` (`app/models/issue.rb`) embarque AASM. 16 états, transitions garanties par `after_all_transitions :persist_status_change!, :emit_activity_event!` qui sauve la row et insère un événement dans `activity_events`.

## Vocabulaire technique → métier

| État AASM | Libellé utilisateur (FR) |
|---|---|
| `pending` | En attente |
| `cloning` | Préparation |
| `checking_spec` | Compréhension de la demande |
| `implementing` | Écriture du code |
| `committing` / `pushing` | Sauvegarde / Envoi sur GitLab |
| `creating_mr` | Ouverture de la demande de fusion |
| `reviewing` | Relecture du travail |
| `checking_pipeline` | Test de la fonctionnalité |
| `fixing_discussions` | Application des retours de relecture |
| `fixing_pipeline` | Correction des tests qui échouent |
| `running_post_completion` | Finalisation |
| `answering_question` | Réponse à une question |
| `needs_clarification` | En attente d'une précision |
| `done` | Livrée |
| `error` | Bloquée, intervention nécessaire |

## Diagramme

```
pending → cloning → checking_spec → implementing → committing → pushing → creating_mr → checking_pipeline
               │          │              │                                                      │
        (closed)          │         (no changes)                                       ┌────────┼────────┐
               ↓          ↓              ↓                                             │        │        │
             done   needs_clarification  error                                    (green)   (red,    (running /
                          ↓                                                            │    code)   canceled)
                       pending                                                         ↓        │        │
                                                                                  reviewing  fixing_   skip
                                                                                 (mr-review) pipeline
                                                                                       │        │
                                                                                       ↓        ↓
                                                                                   checking_pipeline
                                                                                          │
                                                                                          v
                                                                              ┌───────────┴───────────┐
                                                                              │                       │
                                                                       (no discussion)        (has discussion)
                                                                              │                       │
                                                                              ↓                       ↓
                                                                            done           fixing_discussions
                                                                                                    │
                                                                                                    ↓
                                                                                            checking_pipeline
```

## Réentrées et hooks

- `done` + label *à traiter* détecté au poll → `pending` (réentrée).
- `done` + désassigné au poll + `post_completion` configuré → `running_post_completion` → `done`.
- `error` (depuis n'importe quel état actif) → `pending` (retry avec backoff).
- `needs_clarification` (depuis `checking_spec`) → `pending` quand un commentaire de clarification est posté.

## Reset vs Transition (UI)

- **`POST /issues/:id/reset`** — raw SQL `UPDATE` qui force `status = 'pending'`, vide `retry_count`, `error_message`, `next_retry_at`, `started_at`. **N'est pas une transition AASM** — les hooks `after_all_transitions` ne sont pas tirés. Une row est écrite directement dans `audits` via `Audit.record!`.
- **`POST /issues/:id/transition?event=<aasm_event>`** — tire `issue.send("#{event}!")`, qui passe par AASM et déclenche les hooks. Le contrôleur vérifie que l'événement fait partie de `permitted_events_for(issue)` (extracteur AASM des transitions sortantes valides depuis l'état courant).

\newpage

# Cycle de vie côté GitLab

Le dialogue Autodev ↔ GitLab repose sur :

- **L'assignation** : Autodev s'occupe d'un ticket s'il lui est assigné.
- **3 labels** : `label_todo` (*à traiter*), `label_doing` (*en cours*), `label_done` (*livré*). Noms configurables dans `~/.autodev/config.yml`.

Pas de webhook GitLab — Autodev poll régulièrement (`AutodevPollJob` toutes les 5 min par défaut) et choisit ses actions selon l'état.

## Polling

`Autodev::PollDispatcher#run_once` exécute 6 passes par projet, dans cet ordre :

1. `dispatch_new_issues` — nouveaux tickets `label_todo` → action `:process`
2. `dispatch_pipelines` — issues en `checking_pipeline` → action `:check_pipeline`
3. `dispatch_discussions` — issues en `fixing_discussions` → action `:fix_discussions`
4. `dispatch_unassignment` — issues actives plus assignées → `done` inline (pas de job)
5. `dispatch_done_unassigned` — issues `done` désassignées avec `post_completion` configuré → action `:post_completion`
6. `dispatch_retries` — issues `error` + `pending` avec backoff écoulé → `:retry_errored` / `:retry_stuck`

Chaque dispatch enfile un `IssueProcessJob(project_path, issue_iid, action)` sur Solid Queue. `limits_concurrency to: 1, key: "issue-#{path}-#{iid}"` garantit qu'un même ticket n'est jamais traité en parallèle. Le cap global de concurrence est `AUTODEV_MAX_WORKERS` (défaut 3).

## Implémentation (IssueProcessor)

```
start_processing! → clone → clone_complete! → check spec → spec_clear!
  → implement → impl_complete! → commit → commit_complete!
  → push → push_complete! → create MR → mr_created! → checking_pipeline
```

Pour les tickets question/investigation (pas de code) : `question_detected!` → `answering_question` → investigation codebase → réponse postée → `question_answered!` → `done`.

## Pipeline et review (PipelineMonitor)

Tire la pipeline head de la MR via l'API GitLab et applique une matrice de décision :

| Pipeline | Review count | Discussions | Action |
|---|---|---|---|
| Running | * | * | Skip, recheck au poll suivant |
| Green | 0 | * | → `reviewing` (mr-review) → `checking_pipeline` |
| Green | > 0 | aucune | → `done` |
| Green | > 0 | non résolues | → `fixing_discussions` |
| Green | ≥ 3 | * | → `done` avec alerte (cap atteint) |
| Red (code) | * | * | `pipeline_failed_code!` → `fixing_pipeline` |
| Red (infra, 1re fois) | * | * | Retrigger une fois, recheck au poll suivant |
| Red (infra, après retrigger) | * | * | Reste en `checking_pipeline` (manuel) |
| Canceled / skipped | * | * | Reste en `checking_pipeline` (manuel) |

`MAX_REVIEW_ROUNDS = 3`. `review_count` incrémenté uniquement sur succès `mr-review`.

## Correction de pipeline (PipelineFixer)

Récupère les logs complets de chaque job en échec, les écrit dans `tmp/ci_logs/<job_name>.log` du workdir (sans troncature), et appelle `danger-claude` une fois par job en échec (chaque appel produit un commit). Stagnation détectée si la signature SHA256 des noms de jobs en échec se répète 5 fois (configurable via `stagnation_threshold`) — la demande passe alors `done` avec un commentaire d'alerte.

## Correction des discussions (MrFixer)

Clone la branche de la MR, récupère les discussions non résolues, en fixe une par appel `danger-claude -p` + `-c`, résout chaque discussion, pousse. Stagnation détectée par signature des IDs de discussions non résolues. Tire `discussions_fixed!` → `checking_pipeline`.

\newpage

# Catalogue d'erreurs

| Cas | Comportement |
|---|---|
| `danger-claude` non installé | Abort au démarrage |
| `mr-review` non installé | Warning au démarrage, étape review skippée |
| Clone échoue | `error`, retry au prochain poll avec backoff |
| Aucun changement produit par `danger-claude` | `error` |
| Push échoue | Retry avec `--force-with-lease` |
| MR existe déjà pour la branche | Réutilisée |
| Ticket fermé entre poll et processing | Direct `done` (guard `issue_closed?` sur `clone_complete!`) |
| Issues en état actif au boot | `Issue.recover_on_startup!` reset les états transitoires |
| Pipeline rouge (code, pré-triage) | `fixing_pipeline` immédiat (skip retrigger) |
| Pipeline rouge (infra / incertaine, 1re fois) | Retrigger unique, recheck au poll suivant |
| Pipeline rouge (infra / incertaine, après retrigger) | Reste en `checking_pipeline` (manuel) |
| Pipeline canceled / skipped | Reste en `checking_pipeline` (manuel) |
| Stagnation pipeline (5 corrections identiques) | `done` avec commentaire d'alerte |
| Stagnation discussions | `done` avec commentaire d'alerte |
| Limite de review atteinte (3 passes) | `done` avec commentaire d'alerte |
| Désassigné en cours d'implémentation | Direct `done` au poll suivant |
| Interruption en `fixing_pipeline` | Reset à `checking_pipeline` au boot |
| Interruption en `reviewing` | Reset à `checking_pipeline` au boot |
| Échec du hook `post_completion` | Non bloquant : `done` quand même, erreur stockée dans `post_completion_error`, visible via `--errors` et dans `/errors` |
| Interruption en `running_post_completion` | Reset à `done` au boot (non rejoué) |
| Usage Claude exhausted | `AutodevPollJob` gate sur `UsageChecker#available?`, pause silencieuse au lieu de burn les retries |

\newpage

# État sur disque

Tout est sous `~/.autodev/` (override via `AUTODEV_HOME`) :

| Path | Rôle |
|---|---|
| `~/.autodev/config.yml` | Projets + credentials GitLab |
| `~/.autodev/autodev.db` | SQLite primaire — `issues`, `activity_events`, `users`, `projects`, `project_app_commands`, `project_memberships`, `sessions`, `schema_migrations`, `ar_internal_metadata`, `audits` |
| `~/.autodev/autodev_queue.db` | SQLite Solid Queue — 10 tables CRUD-heavy isolées du WAL primaire |
| `~/.autodev/secret_key_base` | Secret Devise + session (généré au premier boot, 0600) |
| `~/.autodev/log/production.log` | Log Rails |
| `~/.autodev/log/autodev-{stdout,stderr}.log` | Capture launchd du supervisor |
| `~/.autodev/tmp/` | Tmp Rails |

Migrations AR sous `db/migrate/` (primaire) et `db/queue_migrate/` (queue). `config/initializers/auto_migrate.rb` les rejoue au boot — idempotent grâce aux `if_not_exists: true`.

## Accès lecture seule à la DB prod

Via NetBird : `ssh bobette-autodev`, puis `sqlite3 'file:.autodev/autodev.db?mode=ro'`.

## Multi-DB

`config/database.yml` route :

- `primary` — pool 10, timeout 30s (couvre les 10 threads Puma).
- `queue` — pool 6, timeout 30s, `migrations_paths: db/queue_migrate`.

SQLite en WAL + `busy_timeout=30000ms` absorbe la contention entre les deux process écrivains (Puma et Solid Queue).
