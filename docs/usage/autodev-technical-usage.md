---
title: "Autodev — Guide technique"
subtitle: "Routes admin, configuration projet, CLI, machine à états"
author: "Modulotech"
date: 2026-08-10
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
| `/issues` | `IssuesController#index` | Liste paginée + filtrable (`?tab=`, `?q=`, `?from=`, `?to=`). Tabs : `active`, `pending`, `errors`, `waiting`, `delivered_review`, `done`, `closed`, `all`. Chaque ligne / carte affiche le demandeur par son **nom** (colonne `issue_author_name`, remplie depuis `gl_issue.author.name` au ingest), via `Web::I18nHelpers#author_display` (fallback `#<author_id>` pour les rows d'avant la colonne, em-dash sinon). Les tabs `errors` / `waiting` / `delivered_review` rendent des cartes « besoin d'un humain » (cause + message + CTA) au lieu du tableau dense — elles remplacent l'ancienne page `/errors` |
| `/issues/:id` | `IssuesController#show` | Détail + activity events (200 derniers) |
| `/issues/:id.json` | `IssuesController#show` | Mêmes données, format JSON |
| `/issues/:id/reset` (POST) | `IssuesController#reset` | Reset brut (raw SQL, pas une transition AASM) |
| `/issues/:id/transition` (POST) | `IssuesController#transition` | Déclenche un événement AASM (`?event=...`) |
| `/issues/:id/close` (POST) | `IssuesController#close` | Clôture manuelle (événement AASM `close`, gatée sur le membership projet) — `closed` depuis n'importe quel état |
| `/issues/:id/deploy_review` (GET) | `IssuesController#deploy_review` | Turbo-frame paresseux : sonde la disponibilité du job `deploy_review` (`Autodev::DeployReview#availability`). Rendu **inconditionnellement** sur chaque page d'issue (task #28) — sur une issue sans branche/MR il renvoie `:no_branch` sans appel GitLab et affiche un bouton désactivé + un motif au lieu de rien |
| `/issues/:id/deploy_review` (POST) | `IssuesController#trigger_deploy_review` | Déclenche le job CI `deploy_review` (redéploiement de l'env de review) |
| `/deploy_review` (GET) | `DeployReviewsController#index` | Sélecteur de projet (parmi les projets visibles) + liste des MR ouvertes (`Autodev::DeployReviewSearch`, **`.auto_paginate`**), chacune avec un `DeployReviewFrame` paresseux ; MR déjà suivie annotée d'un badge vers la fiche issue (task #43). Params `q` (recherche ticket / MR / texte) et `untracked=1` (masquer les MR suivies) — task #45 |
| `/deploy_review/mr` (GET) | `DeployReviewsController#availability` | Sonde paresseuse (`project`, `mr_iid`) — `Autodev::DeployReview#availability` sur une `Target` légère (`project_path`, `branch_name`, `mr_iid`) au lieu d'une row Issue |
| `/deploy_review/mr` (POST) | `DeployReviewsController#trigger` | Déclenche le déploiement (`project`, `mr_iid`), audit `deploy_review.manual`, redirige en conservant `q` / `untracked`. `authorize_project!` (403 hors projets visibles) gate `availability` **et** `trigger` — la sécurité ne repose pas sur l'UI |
| `/projects` | `ProjectsController#index` | Union des rows `projects` + entrées YAML pas encore importées |
| `/projects/new` (+ POST `create`) | `ProjectsController#new`/`#create` | Création d'un projet en base (admin only) — enfile `SyncGitlabMembershipsJob` au succès |
| `/projects/:slug/edit` (+ PATCH `update`) | `ProjectsController#edit`/`#update` | Édition de la config per-projet en base (gatée membership/admin) |
| `/projects/:slug/ticket_templates` (index/new/create) | `TicketTemplatesController` | Modèles de ticket AutoSpec du projet (gaté membership/admin, 404 si pas de row projet) |
| `/projects/:slug/ticket_templates/:id` (edit/update/destroy) | `TicketTemplatesController` | Édition / suppression d'un modèle (`:id` numérique) |
| `/projects/:slug/owners` (POST) | `ProjectOwnersController#create` | Promeut un membre du projet (`user_id`) au rôle `owner` — audit `project.owner_granted`. Gaté `can_manage_owners?` (admin ou owner du projet), 403 sinon ; refus si le candidat n'est pas membre (task #38) |
| `/projects/:slug/owners/:user_id` (DELETE) | `ProjectOwnersController#destroy` | Rétrograde un owner en `contributor` — audit `project.owner_revoked`. Même gate |
| `/projects/:slug` | `ProjectsController#show` | Slug = `group/sub/name` encodé en `group__sub__name` |
| `/stream` | `StreamController#show` | Server-Sent Events, `ActionController::Live` |
| `/locale/:lang` | `LocaleController#update` | Set le cookie `locale`, redirige sur `back` |
| `/autospec_drafts` | `AutospecDraftsController#index` | Brouillons (AutoSpec), tabbé `?tab=` : `all` (défaut), `drafting`, `pending`, `to_validate`, `rejected`, `approved`. Les tabs de statut filtrent les brouillons de l'utilisateur ; `to_validate` est l'ensemble *vote owner* (`AutospecDraft.awaiting_vote_of` — pending sur un projet qu'il possède, pas encore voté) |
| `/autospec_drafts/new` (+ POST `create`) | `AutospecDraftsController` | Formulaire de création + persistance |
| `/autospec_drafts/import` (+ POST `create_from_import`) | `AutospecDraftsController` | Backfill depuis une URL d'issue GitLab. Les images inline du corps (`![…](/uploads/…)`) sont rapatriées en `AutospecAttachment` par `Autospec::IssueImageImporter` — inverse exact de `GitlabSubmitter`, la réécriture vise `rails_blob_path`, la chaîne que `rewrite_markdown` recherche à la soumission. Import dégradé jamais annulé : une image injoignable garde son lien d'origine et alimente `GitlabImporter#warnings`, affiché en flash (`web_autospec_import_images_failed`). Le téléchargement passe par `GitlabHelpers::ImageDownloader.upload_api_url` → `GET /api/v4/projects/:path_encodé/uploads/:secret/:fichier` : le chemin web `<host>/<projet>/uploads/…` est **session-cookie uniquement** et répond `200 text/html` (page de connexion) à une requête `PRIVATE-TOKEN`. L'endpoint d'API répondant `application/octet-stream`, la validation se fait par signature binaire (`sniff_image_type`), jamais sur l'en-tête. Même chemin partagé avec le contexte danger-claude (`fetch_issue_context`) |
| `/autospec_drafts/:id` | `AutospecDraftsController#show` | Éditeur + chat + bandeau d'approbation |
| `/autospec_drafts/:id` (PATCH) | `AutospecDraftsController#update` | Autosave titre/markdown/meta_chips (409 hors `drafting`) |
| `/autospec_drafts/:id/chat` (POST) | `AutospecDraftsController#chat` | Tour de chat (`Autospec::Chat`), 503 si clé Anthropic absente |
| `/autospec_drafts/:id/apply_suggestion` (POST) | `AutospecDraftsController#apply_suggestion` | Applique un `tool_use` proposé par le modèle |
| `/autospec_drafts/:id/{submit_for_approval,retract,approve,reject}` (POST) | `AutospecDraftsController` | Workflow d'approbation (§J) |
| `/autospec_drafts/:id/destroy` (POST) | `AutospecDraftsController#destroy` | Hard-delete d'un brouillon non `submitted` (route brute, pas une action `resources` — Rails replierait un membre `destroy` sur `/:id`). Gaté `authorize_deletable!` (auteur / owner / admin), 409 `draft_not_deletable` si `submitted` (task #39) |
| `/autospec_drafts/:id/autospec_attachments` (POST + DELETE `:id`) | `AutospecAttachmentsController` | Pièces jointes image (ActiveStorage, ≤ 10 Mo) |
| `/help` | `HelpController#show` | Guide utilisateur rendu (`HelpDoc.render(:functional)`) |
| `/help/images/:filename` | `HelpController#image` | Captures d'écran des deux guides (partagé) |
| `/users/auth/entra_id` (+ callback) | Devise | OmniAuth Microsoft 365 |
| `/users/sign_out` (DELETE) | `Users::SessionsController#destroy` | Sign-out custom — `devise_for :users` n'émet pas la ressource `sessions` (le model `User` n'a pas `:database_authenticatable`), ce contrôleur comble le trou |
| `/sign_in` | `SignInController#new` | Page d'atterrissage avec form POST CSRF |
| `/admin/users` | `Admin::UsersController#index` | Audit users + memberships (admin only) |
| `/admin/health` | `Admin::HealthController#show` | Tableau de bord santé système (admin only) |
| `/admin/help` | `Admin::HelpController#show` | Ce guide technique rendu (`HelpDoc.render(:technical)`, admin only) |
| `/admin/jobs` | Mission Control | Inspecteur Solid Queue (admin only) |
| `/up` | `Rails::HealthController#show` | Liveness (le process répond) — **non authentifié** |
| `/healthz(.json)` | `MonitoringController#show` | Santé JSON pour sondes externes, HTTP 200/503 — **non authentifié** |
| `/healthz/:check` | `MonitoringController#component` | Un seul composant (`poller`, `workers`, `queue`, …) — **non authentifié** |

Toutes les routes hors `/sign_in`, SSO et les endpoints de monitoring (`/up`, `/healthz*`) sont gatées par le `before_action :authenticate_user!` global (PR3 du chantier *users-rollout*). Les routes `/admin/*` ajoutent un check `current_user&.admin?` au-dessus. Les endpoints de monitoring sautent volontairement le gate (une sonde externe ne peut pas faire le handshake SSO) — voir `docs/observability.md`.

Pas de chrome custom sur `/admin/jobs` — c'est l'UI fournie par la gem `mission_control-jobs`.

## Comportement temps réel

- `/stream` est une long-lived SSE. Tout `ActivityEvent` créé est publié sur `Web::EventBus` (in-process pub/sub, backpressure drop à 100), puis transformé en Turbo Stream HTML envoyé sur la connexion ouverte.
- Le layout Phlex ouvre une `EventSource('/stream')` au `turbo:load`. Désactivé sous `navigator.webdriver` pour ne pas bloquer les outils d'automation qui attendent `networkidle`.
- Listener `pagehide` côté client : ferme l'`EventSource` à chaque F5 / fermeture d'onglet / navigation cross-document, pour que le thread Puma parqué sur `Queue#pop` soit libéré au prochain write au lieu d'attendre le heartbeat. `StreamController::HEARTBEAT_INTERVAL = 5` secondes en filet de sécurité pour les morts silencieuses (kill navigateur, perte réseau, sleep machine). Voir `docs/autospec.md` §L pour le contexte et les critères pour migrer vers ActionCable + Solid Cable à l'implem AutoSpec.

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

Depuis la task #38, seuls les **contributeurs** sont dérivés de la synchro GitLab (`--sync-memberships`, access-level ≥ 20). Le rôle **owner** est une désignation **manuelle** (onglet *Équipe* d'un projet, `ProjectOwnersController`) : la synchro ne crée, ne rétrograde ni ne révoque jamais un owner. Il n'y a donc pas d'édition des contributeurs depuis l'UI (la sync GitLab fait foi), mais les owners, eux, se gèrent à la main. Pour bootstrapper le premier admin, utiliser `autodev --seed-admin EMAIL`.

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
- **Recurring tasks** — programmées via `config/recurring.yml` : `AutodevPollJob` (poll, `*/N * * * *`), `SyncGitlabMembershipsJob` (réconciliation memberships, `0 3 * * *`), `RefreshProjectBriefingsJob` (briefing AutoSpec horaire, `0 * * * *`), et **en prod uniquement** `clear_solid_queue_finished_jobs` (purge horaire des jobs terminés, minute 12), `LogJanitorJob` (`prune_logs`, rotation/purge des logs, `30 4 * * *`) et `ReapFailedJobsJob` (`reap_transient_failed_jobs`, écarte les échecs process transitoires, `18 * * * *`). Le bloc `development:` est vide — un supervisor local n'auto-poll pas.

À vérifier en cas de souci :

1. Le worker Solid Queue tourne (sinon les `AutodevPollJob` ne s'enquilleraient pas).
2. La tâche récurrente `AutodevPollJob` est bien programmée à l'intervalle attendu.
3. Aucun job n'est resté bloqué en *In Progress* après un crash supervisor.
4. La file *Failed jobs* est vide.

Auth : `current_user&.admin?` requis (cf. `config/initializers/mission_control.rb`).

\newpage

# Admin — Santé du système

URL `/admin/health`. Tableau de bord passif (aucune sonde active : pas de shell-out danger-claude, pas d'appel GitLab au chargement) qui agrège l'état du système via `Autodev::HealthReport`. Accès restreint aux comptes `admin = true`.

Une carte par composant, avec une pastille `OK` / `Attention` / `Hors service` :

- **Poller** — fraîcheur du dernier heartbeat (`ActivityEvent` `kind: 'poller'`). `Hors service` si plus vieux que `poll_interval × monitoring.poll_stale_factor` (plancher 15 min).
- **Workers** — process Solid Queue vivants (heartbeat < 5 min).
- **File de jobs** — jobs en échec / en attente (Solid Queue).
- **Quota Claude** — dernier verdict persisté par `Autodev::UsageGate` (écrit au moment de la sonde, en début de cycle — plus frais que le heartbeat de fin de cycle qu'il lisait avant). Jamais re-sondé ici. `OK` aussi quand aucune sonde n'est sur disque ou que le verdict est périmé : c'est la carte *Poller* qui signale un poller arrêté, pas celle-ci.
- **Issues en erreur** — nombre d'issues `error` / `post_completion_error` (lien vers `/issues?tab=errors`).
- **Issues bloquées** — issues dans un état actif qui n'avancent plus : une `pending` plus vieille que la fenêtre de péremption du poller, ou une issue active sans `ActivityEvent` depuis la fenêtre d'inactivité — `max(monitoring.stuck_active_after_seconds ou 2 h, 2 × le plus long timeout configuré)`, pris sur `dc_timeout`, `mr_review_timeout` et `post_completion_timeout`, donc relever un timeout par projet élargit la fenêtre automatiquement (Autodev #50). Chaque appel danger-claude écrit un heartbeat en base (invisible dans l'UI) pour que la fenêtre mesure la vraie inactivité et pas la durée d'un run. Détecte les orphelines qu'un dashboard tout vert masquait (ex. une `pending` remise au redémarrage mais restée `label_doing` côté GitLab). Exclut `checking_pipeline` (attente pipeline) et `needs_clarification` (attente humaine).
- **Base de données** — primaire + queue joignables.

Les mêmes données sont servies en JSON sur `/healthz` (HTTP 503 uniquement si `down` — vraie panne ; `ok` et `warn` renvoient 200) pour brancher des sondes Datadog / BetterStack. Référence complète (endpoints, heartbeat, configuration, exemples de sondes, TODO) : **`docs/observability.md`**.

\newpage

# Configuration d'un projet

Depuis le task #9 (phases 3-4, `v1.0.0-alpha.25`/`.26`), la config par projet vit **en base**, sur la row `projects`, et s'édite depuis le dashboard. Le bloc `projects:` de `~/.autodev/config.yml` **n'est plus requis** : `~/.autodev/config.yml` ne sert plus que pour les credentials (`gitlab_token`, bloc `azure:`) et comme fallback transitoire pour les projets pas encore importés en base.

## Créer / éditer un projet

- **Créer** : `GET /projects/new` + `POST /projects` (`ProjectsController#new/#create`), **admin uniquement** (`can_create_project?`). `gitlab_path` (immuable) dérive le `slug`/`name`, `default_locale` fixe la langue des commentaires. Au succès, `SyncGitlabMembershipsJob` est enfilé pour peupler les memberships.
- **Éditer** : `GET /projects/:slug/edit` + `PATCH /projects/:slug` (`ProjectsController#edit/#update`), gaté **admin ou collaborateur** du projet (`can_edit_project?` → `current_user.contributor_of?`). Une row `projects` doit exister (sinon 404). Seules les colonnes de config sont persistées (jamais de mass-assignment) ; un champ vidé retombe sur le défaut global.

![Formulaire de création d'un projet (`/projects/new`, admin only).](screenshots/16-project-new.png)

![Édition de la config per-projet (`/projects/:slug/edit`).](screenshots/15-project-edit.png)

## Champs de config (formulaire `/projects/:slug/edit`)

| Section | Champ | Effet |
|---|---|---|
| Général | `target_branch` | Branche cible des MRs (défaut : branche par défaut du dépôt). |
| Général | `labels_todo` / `label_doing` / `label_done` | Les 3 labels du cycle de vie GitLab (listes, une entrée par ligne). |
| Général | `extra_prompt` | Texte ajouté à tous les prompts `danger-claude` du projet. |
| Exécution | `dc_timeout` | Délai max d'un appel `danger-claude` (s). |
| Exécution | `mr_review_timeout` | Délai max d'une exécution de `mr-review` (s, défaut 3600). Au-delà, la review est interrompue et comptée comme un échec ; 5 échecs consécutifs clôturent la demande et la réassignent à son auteur. |
| Exécution | `max_retries` | Nb max de **retries** (pas de tentatives totales) sur échec — défaut `1`, soit 1 retry après le premier échec. Résolu par `Config.max_retries` et comparé de façon inclusive (`retry_count <= max_retries`) à chaque site. Un `max_retries` **global** dans `config.yml` est ignoré (`IGNORED_GLOBAL_FIELDS`) : seuls l'override par projet et le `DEFAULTS` s'appliquent. |
| Exécution | `retry_backoff` | Délai de base entre deux tentatives (s). |
| Exécution | `dormant_audit_max` | Nb max de secondes chances accordées à une ligne dormante (`pending` orpheline, budget de retry épuisé, ou état actif figé) avant abandon (défaut 3, `DEFAULT_DORMANT_AUDIT_MAX`). Ancien nom `error_recheck_max`, toujours accepté. |
| Exécution | `dormant_audit_backoff` | Délai (s) entre deux secondes chances d'audit dormant (défaut 3600, `DEFAULT_DORMANT_AUDIT_BACKOFF`). Ancien nom `error_recheck_backoff`, toujours accepté. |
| Exécution | `stagnation_threshold` | Échecs identiques consécutifs avant abandon. |
| Exécution | `infra_recheck_max` | Nb max de rechecks automatiques d'une stagnation infra (défaut 5, `DEFAULT_INFRA_RECHECK_MAX`). |
| Exécution | `infra_recheck_backoff` | Délai (s) entre deux rechecks infra (défaut 3600, `DEFAULT_INFRA_RECHECK_BACKOFF`). |
| Exécution | `pipeline_watch_max_days` | Borne d'âge absolue d'une surveillance de pipeline, en jours (défaut 14, `Config::DEFAULTS`). Au-delà, la demande est abandonnée : `done` + `needs_attention` (`pipeline_watch_expired`) + `label_done` + commentaire GitLab. `0` désactive la borne. Comme `infra_recheck_max`, ce réglage est lu dans `@project_config` puis dans la config globale, **mais n'est pas une colonne de `projects`** : pour un projet en base, `to_project_config` n'émet que ses colonnes, donc seul le réglage global s'applique aujourd'hui. |
| Exécution | `clone_depth` | Profondeur du `git clone` (0 = historique complet). |
| Exécution | `sparse_checkout` | Chemins du sparse checkout (liste, pour monorepos). |
| Exécution | `post_completion` | Commande(s) lancée(s) après livraison (sur désassignation). |
| Exécution | `post_completion_timeout` | Délai max de la commande `post_completion` (s). |
| Avancé | `model` | Modèle `danger-claude` (option `-m`). |
| Avancé | `effort` | Effort de raisonnement `danger-claude` (option `-e`). |
| Avancé | `parallel_agents` | Découpe les issues complexes sur plusieurs agents (worktrees git). |
| Avancé | `split_implementation` | Implémente code puis tests en deux passes distinctes. |
| Avancé | `implementer_agent` / `test_writer_agent` / `mr_fixer_agent` | Agents custom (nom ou chemin dans `.claude/agents`). |

Les commandes d'environnement (`setup`/`test`/`lint`/`run`) vivent à part dans la table `project_app_commands` (sous-bloc `app:` en YAML), reconstruites par `Project#to_project_config`. Le `run` avec au moins un `port` auto-active Chrome DevTools pour les captures d'écran. Tri-état des booléens : *Défaut* (suit le global) / *Activé* / *Désactivé*.

## Résolution DB vs YAML

`IssueProcessJob#lookup_project_config` résout dans cet ordre :

1. **Row `projects`** → `Project#to_project_config` (autoritaire ; n'émet que les clés présentes, se superpose proprement aux défauts globaux).
2. **Fallback YAML** : entrée `projects:` de `config.yml` correspondant au path, si aucune row.
3. Ni l'un ni l'autre → l'issue est skippée.

`Project.runtime_configs` (discovery côté poller / boot) fait la même union DB-puis-YAML. Pour migrer un bloc `projects:` YAML en base : `bin/rails autodev:migrate_projects_from_yaml` (transactionnel, `DRY_RUN=1` pour un essai à blanc).

## Synchronisation GitLab

Les memberships sont alimentés par `autodev --sync-memberships` (manuel ou via la tâche planifiée `0 3 * * *`).

`Autodev::GitlabMembershipSync` mappe l'access-level GitLab ≥ 20 (reporter) vers `contributor`, et rien en dessous — le seuil `owner` a disparu du mapping (task #38). À la réconciliation, les rows `owner` sont **exclues** : jamais rétrogradées, jamais révoquées. Le rôle `owner` est donc désormais posé **exclusivement à la main** via l'onglet *Équipe* de la page projet, et sert de marqueur fiable de « désignation manuelle » (aucune colonne dédiée). Une data-migration (`20260710000001_convert_project_owners_to_contributors`) a rétrogradé tous les owners hérités de l'ancienne synchro : après déploiement, un projet n'a plus aucun owner tant qu'un admin n'en désigne (amorçage manuel assumé).

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

Le modèle `Issue` (`app/models/issue.rb`) embarque AASM. 17 états, transitions garanties par `after_all_transitions :persist_status_change!, :emit_activity_event!, :emit_audit_log!` qui sauve la row, insère un événement dans `activity_events`, et trace une ligne d'`audits` (`issue.transition_manual` avec acteur si déclenchée depuis l'UI, sinon `issue.transition_auto` avec acteur NULL).

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
| `done` | Livrée (libellé *Livrée (à vérifier)* quand un cap/stagnation a forcé la livraison) |
| `error` | Bloquée, intervention nécessaire |
| `closed` | Clôturée |

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

- `done` + label *à traiter* détecté au poll → réentrée (`PollRouter::ResumeHandler`), routée selon l'état de la MR : MR **mergée** → on ne fait rien (travail déjà livré, label *livré* ré-appliqué) ; MR **ouverte** → `checking_pipeline` (→ `fixing_discussions`) pour traiter les retours de relecture *sauf* si un **nouveau commentaire humain a été posté sur le ticket après la dernière livraison** (`finished_at`), auquel cas → `pending` pour une **ré-implémentation** complète qui réutilise la branche/MR existantes et intègre le commentaire (retour de recette KO) ; MR **fermée / absente** → `pending` (ré-implémentation).
- `done` + désassigné au poll + `post_completion` configuré → `running_post_completion` → `done`.
- `error` (depuis n'importe quel état actif) → `pending` (retry avec backoff).
- `needs_clarification` (depuis `checking_spec`) → `pending` quand un commentaire de clarification est posté.
- `close` (depuis n'importe quel état) → `closed`. Tiré **manuellement** par `POST /issues/:id/close`, ou **automatiquement** par `dispatch_unassignment` quand le ticket est passé à `closed` côté GitLab (voir §*Passes de dispatch*). État terminal : le poller ignore toute issue dont le `status != 'pending'`. La réouverture n'est **pas** automatique — un ticket GitLab rouvert ne réveille pas la row ; utiliser `#reset`.
- Ligne dormante — `pending` sans `next_retry_at`, `error` à budget de retry épuisé (`retry_count > max_retries`), ou état actif figé (`Issue::STALLED_STATES`, ex. `cloning`, `fixing_discussions`, `answering_question`…) sans activité récente → `dispatch_dormant_audit` lui donne un nombre borné de secondes chances (une lecture GitLab par tour) : ticket clôturé → `closed` ; plus assigné → `done` ; toujours à nous → budget ré-armé (repris ensuite par `dispatch_retries`, qui tourne juste après) ou état actif relancé via `Issue.revive_stalled!`. Au-delà de `dormant_audit_max` tours infructueux : `needs_attention` (`dormant_exhausted`), sans commentaire GitLab. Remplace `dispatch_error_recheck`, dont l'`error`-population n'était qu'un des trois cas.
- `done` + `needs_attention` + `attention_reason: 'stagnation_pipeline'` + MR ouverte → recheck auto (`:recheck_infra`) ; si la pipeline courante a récupéré, réentrée en `checking_pipeline` (voir §*Recheck automatique d'une stagnation infra*). Borné par `infra_recheck_max` / `infra_recheck_backoff`.

## Reset vs Transition (UI)

- **`POST /issues/:id/reset`** — délègue à `Issue.reset_for_retry!(scope, reset_budget: true, clear_attention: true)`, le point de vérité partagé avec le `--reset` CLI et `Issue.recover_errored!`. Raw SQL `UPDATE`, donc **pas une transition AASM** — les hooks `after_all_transitions` ne sont pas tirés ; une row est écrite directement dans `audits` via `Audit.record!`. La règle appliquée a deux moitiés : une row **avec MR** reprend en `checking_pipeline` (que `dispatch_pipelines` interroge sans condition), une row **pré-MR** repart en `pending` **avec un `next_retry_at` dû** — `fetch_retryable` exige un stamp non NULL et `dispatch_new_issues` ne redécouvre que les `labels_todo` alors que la row porte encore `label_doing`, donc sans le stamp elle est orpheline (motif du task #26). `reset_budget:` distingue les deux intentions : un reset opérateur remet `retry_count` à 0, la reprise automatique au démarrage le préserve.
- **`POST /issues/:id/transition?event=<aasm_event>`** — tire `issue.send("#{event}!")`, qui passe par AASM et déclenche les hooks. Le contrôleur vérifie que l'événement fait partie de `permitted_events_for(issue)` (extracteur AASM des transitions sortantes valides depuis l'état courant).
- **`POST /issues/:id/close`** — clôture manuelle par un collaborateur du projet (gatée sur le membership). Tire l'événement AASM `close` depuis n'importe quel état → `closed` (terminal). Passe par les hooks (trace un audit). Rouvrir via `#reset`.

\newpage

# Cycle de vie côté GitLab

Le dialogue Autodev ↔ GitLab repose sur :

- **L'assignation** : Autodev s'occupe d'un ticket s'il lui est assigné.
- **3 labels** : `label_todo` (*à traiter*), `label_doing` (*en cours*), `label_done` (*livré*). Noms configurables dans `~/.autodev/config.yml`.

Pas de webhook GitLab — Autodev poll régulièrement (`AutodevPollJob` toutes les 5 min par défaut) et choisit ses actions selon l'état.

## Polling

`Autodev::PollDispatcher#dispatch` exécute 8 passes par projet, dans cet ordre :

1. `dispatch_new_issues` — nouveaux tickets `label_todo` → action `:process`
2. `dispatch_pipelines` — issues en `checking_pipeline` → action `:check_pipeline`
3. `dispatch_discussions` — issues en `fixing_discussions` → action `:fix_discussions`
4. `dispatch_unassignment` — issues actives : **une seule** lecture GitLab par row (`@client.issue`) qui tranche deux cas — ticket `closed` côté GitLab → `closed` inline via l'événement AASM `close` (`finished_at` stampé, trio `needs_attention` vidé) ; sinon plus assignée → `done` inline. La clôture l'emporte sur la désassignation. Pas de job dans les deux cas. Seules les rows **actives** sont balayées : un ticket clos alors qu'il était en `pending`/`error` est vu à son prochain mouvement
5. `dispatch_done_unassigned` — issues `done` désassignées avec `post_completion` configuré → action `:post_completion`
6. `dispatch_dormant_audit` — balaie trois populations qui ont cessé de bouger : `pending` sans `next_retry_at`, `error` à budget de retry épuisé (`retry_count > max_retries`), et état actif figé (`Issue::STALLED_STATES` — `cloning`, `implementing`, `fixing_discussions`, `answering_question`, etc.) sans activité récente. Une lecture GitLab par candidat tranche : ticket clôturé → `closed` ; plus assigné → `done` ; toujours à nous → budget ré-armé (`retry_count` à 0 + `next_retry_at` dû, consommé par `dispatch_retries` juste après) ou état actif relancé via `Issue.revive_stalled!`. Bornée par `dormant_audit_max` (défaut 3) tentatives espacées de `dormant_audit_backoff` (défaut 3600 s) ; au-delà, la row passe `needs_attention` (`dormant_exhausted`) sans lecture GitLab supplémentaire. Remplace `dispatch_error_recheck`, dont l'`error`-population n'était qu'un des trois cas ; réglages `error_recheck_max`/`error_recheck_backoff` toujours acceptés en fallback. Placée **avant** `dispatch_retries` pour qu'un budget ré-armé soit consommé dans le même cycle
7. `dispatch_retries` — issues `error` + `pending` avec backoff écoulé → `:retry_errored` / `:retry_stuck`
8. `dispatch_infra_recheck` — issues `done` + `needs_attention` + `attention_reason: 'stagnation_pipeline'`, MR ouverte, sous le cap et backoff écoulé → action `:recheck_infra` (re-tentative auto d'une stagnation infra, voir plus bas)

Chaque dispatch enfile un `IssueProcessJob(project_path, issue_iid, action)` sur Solid Queue. `limits_concurrency to: 1, key: "issue-#{path}-#{iid}"` garantit qu'un même ticket n'est jamais traité en parallèle. Le cap global de concurrence est `AUTODEV_MAX_WORKERS` (défaut 3).

### Gate de quota Claude (par passe)

`AutodevPollJob` sonde le quota **une fois par cycle** via `Autodev::UsageGate.probe!` et persiste le verdict dans un `ActivityEvent(kind: 'usage')`. Le verdict descend ensuite dans chaque `PollDispatcher` (`usage_ok:`) et ne bloque que ce qui aboutit à un appel `danger-claude` / `mr-review` :

| Passe / action | Quota épuisé |
|---|---|
| `dispatch_new_issues` (`:process`) | **sautée** |
| `dispatch_discussions` (`:fix_discussions`) | **sautée** |
| `dispatch_retries` → `:retry_stuck` | **sautée** |
| `dispatch_retries` → `:retry_errored` | tourne (transitions + labels) |
| `dispatch_pipelines` (`:check_pipeline`) | tourne |
| `dispatch_unassignment` (dont clôture GitLab) | tourne |
| `dispatch_done_unassigned` (`:post_completion`) | tourne (commande shell) |
| `dispatch_dormant_audit` | tourne |
| `dispatch_infra_recheck` (`:recheck_infra`) | tourne |

`:check_pipeline` continue d'être enfilée, donc `PipelineMonitor` porte son propre gate aux deux points qui appellent Claude : pipeline verte avec `review_count == 0` (mr-review) et branche `code` de `triage_and_fix`. Le premier est placé **avant** `log_activity(:pipeline_green)` (sinon une coupure longue ajoute une ligne à la note GitLab à chaque poll et fait sauter le cap de 1 M caractères) ; le second retourne **avant** `update_stagnation_signature` (sinon un cycle en pause brûle le budget de stagnation). `IssueProcessJob` porte une garde défensive pour les jobs déjà en file (`:process`, `:fix_discussions`, `:retry_stuck`).

Tout échoue **ouvert** : absence de sonde, payload illisible, ou verdict plus vieux que `max(2 × poll_interval, 600 s)` se lisent « disponible ». Ne pas réussir à *observer* le quota ne doit jamais arrêter le pipeline. Le verdict est lu par `HealthReport#check_claude_usage` et par la bannière du dashboard (`Autodev::UsageGate.state`).

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

Quand la pipeline bloque sur un échec `:infra`/deploy (`FailureHandler#infra_skip?`), le job en cause et sa `failure_reason` GitLab ne sont plus perdus : `format_failure_detail` construit une chaîne concise (ex. `deploy_review (script_failure)`, séparés par virgule pour plusieurs jobs, URL du job GitLab ajoutée si l'API l'expose). Ce détail est (1) **persisté** sur la colonne `attention_detail` de l'issue (vidée à la réentrée / reset / close, comme les autres colonnes d'attention), (2) **injecté** dans la notification `stagnation_pipeline` et les lignes d'activité `activity_stagnation_pipeline` / `activity_pipeline_infra` via le placeholder `%{detail}`, et (3) **affiché** sur la carte de surveillance needs_attention / delivered_review (`web_errors_attention_detail`). `attention_reason` reste `stagnation_pipeline`.

## Correction des discussions (MrFixer)

Clone la branche de la MR, récupère les discussions non résolues, en fixe une par appel `danger-claude -p` + `-c`, résout chaque discussion, pousse. Stagnation détectée par signature des IDs de discussions non résolues. Tire `discussions_fixed!` → `checking_pipeline`.

## Recheck automatique d'une stagnation infra (task #31)

Un ticket abandonné sur une stagnation infra/deploy (`done` + `needs_attention` + `attention_reason: 'stagnation_pipeline'` + `label_done`) n'est plus terminal : la pass `dispatch_infra_recheck` le ré-enfile en `IssueProcessJob(:recheck_infra)` tant qu'il reste ouvert, sous le cap `infra_recheck_max` et le backoff `infra_recheck_backoff` écoulé.

`PipelineMonitor#recheck_infra_recovery` (`pipeline_monitor/infra_recheck.rb`) re-classe la pipeline head **courante** de la MR avec les mêmes `pre_triage`/`job_classifier` (infra-vs-code décidé au moment du recheck sur les jobs qui échouent *actuellement*, jamais un verdict stocké) :

- **Pipeline recovered** (verte / plus rien qui échoue) → réentrée via `ResumeHandler#reenter_via_pipeline_check` (retour à `checking_pipeline`, `needs_attention` vidé, compteurs review/fix remis à zéro, `label_doing` ré-appliqué, `infra_recheck_count`/`infra_recheck_at` réinitialisés).
- **Toujours infra** → on attend, une tentative bornée est enregistrée (`infra_recheck_count += 1`, `infra_recheck_at` re-stampé).
- **Maintenant code** → laissé intact (vraie erreur à corriger à la main).

Chaque non-recovery consomme une tentative, donc le recheck s'auto-limite au cap : une infra qui ne récupère jamais reste en `needs_attention` définitivement, sans boucler. `stagnation_discussions` n'est jamais visé. Colonnes ajoutées (migration `20260706000002_add_infra_recheck_to_issues`) : `infra_recheck_count`, `infra_recheck_at`.

\newpage

# AutoSpec — rédaction assistée de tickets

Feature de la phase D (`docs/autospec.md` §A/E/G/J), livrée end-to-end à `v1.0.0-alpha.18`. Permet à un utilisateur de **rédiger un futur ticket en discutant avec Claude**, puis de le router vers un développeur humain ou vers Autodev après validation des owners. Distinct du moteur d'implémentation décrit plus haut — c'est une UI de cadrage en amont.

![Éditeur AutoSpec — le brouillon à gauche, le chat avec Autodev à droite.](screenshots/13-autospec-editor.png)

## Modèle et états

`AutospecDraft` (`app/models/autospec_draft.rb`) monte AASM (`column: :status`, `whiny_transitions: false`). 4 états :

| État | Événement entrant | Sens |
|---|---|---|
| `drafting` (initial) | `retract` / `resume_from_rejection` | rédaction / chat / autosave |
| `pending_approval` | `submit_for_approval` (incrémente `current_iteration`) | en attente du vote des owners |
| `rejected` | `mark_rejected` | un owner a refusé (motif sur la row `autospec_approvals`) |
| `submitted` | `finalize` | quorum atteint, issue GitLab créée |

`destination` ∈ {`human`, `autodev`} (nullable jusqu'à la soumission). `meta_chips` est un JSON (`type`, `priority`, `tags`).

## Matrice de permissions (§J)

Prédicats portés par le modèle (appelés par le contrôleur ET les vues pour décider des boutons) :

- `viewable_by?` — admin OU auteur (tout état) OU owner du projet (uniquement `pending_approval`/`submitted`/`rejected`). Un contributeur non-auteur ne voit jamais le brouillon d'autrui.
- `editable_by?` / `submittable_by?` — auteur + `drafting`.
- `destination_choosable_by?` — contributeur-auteur → `human` seulement ; owner-auteur → `human` ou `autodev` (le « envoyer à AutoDev » est un verrou produit owner-only).
- `retractable_by?` — auteur + `pending_approval`.
- `votable_by?` — owner du projet + `pending_approval` (l'idempotence « déjà voté à cette itération » est vérifiée par `ApprovalRecorder`, pas ici).
- `deletable_by?` — non `submitted` ET (auteur OU owner du projet OU admin) : autorise le hard-delete tant que le brouillon n'est pas validé (`drafting` / `pending_approval` / `rejected`) — task #39.

`AutospecDraftsController` applique quatre before-actions : `authorize_view!` (show), `authorize_voter!` (approve/reject), `authorize_deletable!` (destroy), `authorize_author!` (le reste). `authorize_deletable!` vérifie le **rôle** (403 si ni auteur, ni owner, ni admin) indépendamment de l'état ; la garde d'**état** (409 `draft_not_deletable` sur un brouillon `submitted`, déjà exporté vers GitLab) est appliquée dans `#destroy`. Les dépendances (`autospec_messages` / `autospec_attachments` / `autospec_approvals`) sont nettoyées par les `dependent: destroy` existants.

## Services

| Service | Rôle |
|---|---|
| `Autospec::Chat` | Tour de chat via le SDK Anthropic. `api_key_configured?` (ENV `ANTHROPIC_API_KEY` > `anthropic.api_key` config > test seam) gate l'UI et renvoie un 503 côté contrôleur si absente. |
| `Autospec::SystemPrompt` | Construit le prompt système (persona + briefing projet + état du brouillon) avec breakpoints de cache `ephemeral`. |
| `Autospec::ProjectBriefer` | Clone `staging` (fallback HEAD distant via `git ls-remote --symref`), lance `danger-claude -p <briefing>`, stocke `Project.briefing_text`. |
| `Autospec::SuggestionApplier` | Applique un `tool_use` du modèle au brouillon (titre/markdown/meta_chips). Erreurs typées → 409 / 404 / 422. |
| `Autospec::ApprovalRecorder` | Enregistre un vote owner par itération (transactionnel). 1er refus → `mark_rejected!` ; quorum (tous les owners ont approuvé à `current_iteration`) → `GitlabSubmitter#submit!` puis `finalize!`. |
| `Autospec::GitlabSubmitter` | Upload des pièces jointes, réécrit les URLs `/rails/active_storage/...` → `/uploads/...`, crée l'issue (`labels_todo` envoyé seulement si `destination == 'autodev'`). Stamp `gitlab_issue_iid` / `gitlab_issue_url` / `submitted_at`. |
| `Autospec::GitlabImporter` | Parse une URL d'issue GitLab, vérifie l'accès (admin OU `contributor_of?`), pré-remplit un brouillon. `ISSUE_URL_RE` accepte les deux formes `/-/issues/<iid>` **et** `/-/work_items/<iid>` (même IID, même appel `client.issue`). 4 erreurs typées → clés `flash[:alert]`. |
| `Autospec::MarkdownRenderer` | Rendu HTML de l'aperçu du brouillon. |

## Briefing projet

Trois colonnes sur `projects` (`db/migrate/20260616000001`) : `briefing_text`, `briefing_generated_at`, `briefing_error`. `RefreshProjectBriefingsJob` (`0 * * * *`, bloc prod uniquement) régénère le briefing sur `staging` — échec par projet non bloquant (le briefing précédent reste, l'erreur est stockée sur `briefing_error`). `SystemPrompt#build` insère le briefing comme 3e bloc `text` (2e breakpoint cache) quand présent, ce qui laisse l'état du brouillon comme seul chunk non caché de l'appel LLM.

## Modèles de ticket (task #14)

Un projet peut définir des modèles de ticket nommés qu'AutoSpec suit automatiquement. Modèle `ProjectTicketTemplate` (`belongs_to :project`) : colonnes `name`, `slug` (dérivé du nom, minuscule/sans accents, unique par projet, format `\A[a-z0-9]+(?:-[a-z0-9]+)*\z`), `body` (markdown), `position`. Migration `db/migrate/20260624000001`.

CRUD : `/projects/:slug/ticket_templates` (`TicketTemplatesController`, index/new/create/edit/update/destroy), gaté **comme l'éditeur de config** (admin ou collaborateur, 404 si pas de row projet). Deux points d'entrée pour les éditeurs : bouton **« Gérer les modèles »** sur la topbar de `/projects/:slug` et carte sur la page de config.

![Liste des modèles de ticket d'un projet (Évolution, Bug, Question).](screenshots/17-ticket-templates-list.png)

![Édition d'un modèle de ticket (nom, slug, structure markdown).](screenshots/18-ticket-template-form.png)

Le choix du modèle à la création d'un brouillon est persisté : `autospec_drafts.ticket_template_id` (FK nullable, `on_delete: :nullify`, migration `20260625000001`). `Autospec::SystemPrompt#ticket_templates` branche en trois :

1. **Modèle choisi** → AutoSpec le suit et, à chaque évaluation qualité, vérifie le ticket contre lui (sections manquantes / vides / en trop).
2. **Aucun choix mais le projet en a** → AutoSpec propose le mieux adapté et offre de restructurer.
3. **Projet sans modèle** → structure générale par défaut (clé i18n `web_autospec_default_template_body` : Contexte / Comportement attendu / Critères d'acceptation / Notes, dans la locale du brouillon).

Sur `/autospec_drafts/new`, le picker pré-remplit le markdown côté client (`autospec_new.js`, map JSON embarquée) et côté serveur (`#chosen_template`) pour fonctionner JS off. Le champ est envoyé en `template_slug` pour ne pas heurter le `:slug` (projet) de la route.

## Auto-évaluation à la création (task #15)

`AutospecDraftsController#create` (et `#create_from_import`) appelle `auto_evaluate_quality(draft)` : un premier tour de chat via `Autospec::Chat` avec le prompt `web_autospec_auto_eval_prompt` (« Évalue la qualité du ticket. ») dans la locale du projet, de sorte que l'auteur arrive avec une évaluation déjà postée. **Skippé** si le brouillon est vierge (ni titre ni markdown) et si aucune clé Anthropic n'est configurée. **Best-effort** : toute erreur est loggée et ne bloque jamais la création. Exécuté inline (pas de plumbing live-update — déféré au streaming step 9c).

## Tables

DB primaire : `autospec_drafts` (dont `ticket_template_id`), `autospec_messages`, `autospec_attachments`, `autospec_approvals`, `project_ticket_templates`, plus les 3 tables ActiveStorage (`active_storage_blobs`, `active_storage_attachments`, `active_storage_variant_records`) pour les pièces jointes image. Migrations `db/migrate/20260612000001..05`, `20260624000001` (templates), `20260625000001` (lien brouillon→modèle).

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
| Ticket clôturé sur GitLab pendant le travail | `dispatch_unassignment` le détecte au tour suivant (aucun appel API en plus) → événement `close` → `closed`, `finished_at` stampé, `needs_attention` vidé, entrée `activity_closed_externally`. Rows **actives** uniquement |
| Ligne dormante (`pending` sans `next_retry_at`, `error` à budget de retry épuisé, état actif figé) | `dispatch_dormant_audit` (anciennement `dispatch_error_recheck`, dont l'`error`-population n'était qu'un des trois cas) lui donne un nombre borné de secondes chances : clôturé sur GitLab → `closed`, plus assigné → `done`, toujours à nous → budget ré-armé ou état actif relancé. Au plus `dormant_audit_max` (3) tours, espacés de `dormant_audit_backoff` (3600 s) ; au-delà : `needs_attention` (`dormant_exhausted`), sans commentaire GitLab. Colonnes `dormant_recheck_count` / `dormant_recheck_at` (migrations `20260805000001_add_error_recheck_to_issues` puis `20260807000001_rename_error_recheck_to_dormant_recheck`) ; réglages `error_recheck_max`/`error_recheck_backoff` toujours acceptés en fallback |
| Interruption en `fixing_discussions` / `answering_question` | Relancée par `Issue.revive_stalled!` — au boot, et si le service ne redémarre pas, par `dispatch_dormant_audit` |
| Issues en état actif au boot | `Issue.recover_on_startup!` reset les états transitoires |
| Pipeline rouge (code, pré-triage) | `fixing_pipeline` immédiat (skip retrigger) |
| Pipeline rouge (infra / incertaine, 1re fois) | Retrigger unique, recheck au poll suivant |
| Pipeline rouge (infra / incertaine, après retrigger) | Reste en `checking_pipeline` (manuel) |
| Pipeline canceled / skipped | Reste en `checking_pipeline` (manuel), **borné** par `pipeline_watch_max_days` |
| Stagnation pipeline (5 corrections identiques) | `done` + `needs_attention` (`stagnation_pipeline`), commentaire d'alerte incluant le job en cause (`attention_detail`, ex. `deploy_review (script_failure)`). Re-tentative auto une fois CI rétablie (voir ligne suivante) |
| Stagnation pipeline infra — CI rétabli | `dispatch_infra_recheck` ré-enfile `:recheck_infra` ; pipeline courante verte → réentrée `checking_pipeline`. Borné par `infra_recheck_max` (5) / `infra_recheck_backoff` (3600 s) ; jamais de boucle |
| Surveillance de pipeline trop ancienne (aucune transition depuis `pipeline_watch_max_days`, défaut 14 j) | `done` + `needs_attention` (`pipeline_watch_expired`) + `label_done` + commentaire GitLab. Filet de sécurité indépendant du statut de la pipeline : la stagnation n'est alimentée que par la branche rouge, donc une pipeline `manual` / `canceled` / `skipped` — ou restée `created` — n'accumule aucune signature et n'était jamais abandonnée. Horloge : colonne `issues.checking_pipeline_since`, écrite à chaque transition AASM et semée par `PollTracker` pour les lignes arrivées par `update_all`. Vérifié **après** le poll et seulement si la ligne n'a pas bougé, donc une pipeline verte au 15e jour se termine normalement. Volontairement pas `stagnation_pipeline` : `dispatch_infra_recheck` sélectionne cette raison-là et ré-armerait la ligne |
| Stagnation discussions | `done` avec commentaire d'alerte |
| Limite de review atteinte (3 passes) | `done` avec commentaire d'alerte |
| Désassigné en cours d'implémentation | Direct `done` au poll suivant |
| Interruption en `fixing_pipeline` | Reset à `checking_pipeline` au boot |
| Interruption en `reviewing` | Reset à `checking_pipeline` au boot |
| Échec du hook `post_completion` | Non bloquant : `done` quand même, erreur stockée dans `post_completion_error`, visible via `--errors` et dans l'onglet *Livrée (à vérifier)* (`/issues?tab=delivered_review`) |
| Interruption en `running_post_completion` | Reset à `done` au boot (non rejoué) |
| Usage Claude exhausted | Gate **par passe** (`Autodev::UsageGate`) : seules les passes qui appellent `danger-claude` / `mr-review` sont sautées. Suivi des pipelines, clôtures GitLab, post-completion et rechecks continuent — une coupure ne gèle plus les tickets déjà implémentés. Bandeau warn sur le dashboard, carte *Quota Claude* sur `/admin/health`. Fail-open sur sonde absente / illisible / périmée |

\newpage

# État sur disque

Tout est sous `~/.autodev/` (override via `AUTODEV_HOME`) :

| Path | Rôle |
|---|---|
| `~/.autodev/config.yml` | Projets + credentials GitLab |
| `~/.autodev/autodev.db` | SQLite primaire — `issues`, `activity_events`, `users`, `projects`, `project_app_commands`, `project_ticket_templates`, `project_memberships`, `sessions`, `schema_migrations`, `ar_internal_metadata`, `audits`, les tables AutoSpec (`autospec_drafts`, `autospec_messages`, `autospec_attachments`, `autospec_approvals`) et ActiveStorage (`active_storage_blobs`, `active_storage_attachments`, `active_storage_variant_records`) |
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
