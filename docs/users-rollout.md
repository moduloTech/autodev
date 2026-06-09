# Mise en place des utilisateurs — Spec

**Date :** 2026-06-09
**Scope :** Authentification Microsoft 365 SSO appliquée au dashboard existant, memberships dérivés de GitLab par synchronisation, audit trail nominatif. **Pas d'AutoSpec** (phase D reste ouverte).
**Pré-requis :** Devise + omniauth Entra ID câblés depuis step 3 (commit `8af273f`). Table `users` + `project_memberships` existent, aucune row en prod, aucun `authenticate_user!` actif.
**Livraison :** trois PRs séquentiels — voir [§7](#7-plan-de-livraison--3-prs).

Ce document fige les décisions prises pendant l'interview de cadrage du 2026-06-09. Il vit à côté de [`autospec.md`](autospec.md) (qui reste la référence pour le futur AutoSpec) et de [`railsification-postmortem.md`](railsification-postmortem.md) (retour sur la migration Sinatra→Rails).

---

## 1. Objectifs et non-objectifs

### Objectifs

- Gater le dashboard derrière Microsoft 365 SSO. Le NetBird mesh seul ne suffit plus comme contrôle d'accès.
- Provisionner les comptes automatiquement à la première connexion Entra ID.
- Dériver les memberships projet depuis GitLab : la sync GitLab fait foi, pas d'édition manuelle.
- Tracer nominativement reset/transition manuels, transitions AASM automatiques, changements de memberships.
- Préparer le terrain pour AutoSpec sans en démarrer l'implémentation. Les memberships et la table users sont les briques communes.

### Non-objectifs

- Pas d'UI d'édition des memberships (la sync GitLab est autoritaire).
- Pas de notifications email/Teams (cf [autospec.md §K](autospec.md#k-notifications)).
- Pas de greenfield AutoSpec (drafts, AutospecChat, etc.) — autre chantier.
- Pas de granularité de rôle supplémentaire au-delà de `admin` (plateforme) + `owner` / `contributor` (projet).

---

## 2. Modèle

### `User`

Table créée à step 3 (Devise + omniauth Entra ID). Extensions PR2 :

```ruby
add_column :users, :admin, :boolean, null: false, default: false
add_column :users, :gitlab_user_id, :integer
add_column :users, :gitlab_username, :string
add_column :users, :disabled_at, :datetime
add_index :users, :gitlab_user_id, unique: true
```

- `admin` : flag plateforme-wide. Voit tous les projets (bypass de la visibilité par membership). Peut consulter la page d'admin read-only.
- `gitlab_user_id` / `gitlab_username` : résolus à la première sync. Servent à appeler `/projects/:id/members/all` côté GitLab et matcher les rows.
- `disabled_at` : posé quand la sync constate qu'un user a perdu toutes ses memberships ≥ Reporter. `User#active_for_authentication?` retourne `false` si non NULL ⇒ Devise refuse le login.

`User.from_omniauth(auth)` au callback Entra ID :

1. Cherche `User.find_by(email: auth.info.email)`.
2. Si absent : `User.create!(...)` puis lance `GitlabMembershipSync.for_user!(user)`.
3. Si la sync ne produit aucun membership ≥ Reporter, raise `AccessDenied` (la création reste, on logge `user.created` puis `user.disabled` dans audit_log).
4. Sinon, le row reste utilisable et le sign_in passe.

### `ProjectMembership`

Schéma inchangé depuis step 3 :

```ruby
create_table :project_memberships do |t|
  t.references :user, null: false, foreign_key: true
  t.references :project, null: false, foreign_key: true
  t.string :role, null: false   # 'contributor' | 'owner'
  t.timestamps
end
add_index :project_memberships, %i[user_id project_id], unique: true
```

Pas d'enrichissement nécessaire pour ce chantier. Pas de colonne `source` : la sync GitLab est la seule voie de création (à part `seed_admin` qui ne touche pas memberships).

### `AuditLog` — table nouvelle (PR1)

```ruby
create_table :audit_logs do |t|
  t.string :resource_type, null: false             # 'Issue' | 'ProjectMembership' | 'User'
  t.bigint :resource_id, null: false
  t.string :action, null: false                    # cf table actions ci-dessous
  t.references :actor, foreign_key: { to_table: :users }, null: true
  t.jsonb :payload, null: false, default: {}
  t.datetime :created_at, null: false
end
add_index :audit_logs, %i[resource_type resource_id]
add_index :audit_logs, :actor_id
add_index :audit_logs, :created_at
```

`actor_id` NULL = action automatique (poller, job récurrent). `payload` capture l'info contextuelle (état précédent, source de la sync, etc.).

**Actions reconnues :**

| Action | Payload | actor_id |
|---|---|---|
| `issue.reset_manual` | `{ project_path, iid, previous_state }` | utilisateur connecté |
| `issue.transition_manual` | `{ project_path, iid, event, from, to }` | utilisateur connecté |
| `issue.transition_auto` | `{ project_path, iid, event, from, to }` | NULL |
| `membership.granted` | `{ user_id, project_id, role, source: 'gitlab_sync' }` | NULL (sync job ou login callback) |
| `membership.revoked` | `{ user_id, project_id, previous_role, source: 'gitlab_sync' }` | NULL |
| `membership.role_changed` | `{ user_id, project_id, from_role, to_role }` | NULL |
| `user.created` | `{ source: 'omniauth' \| 'seed_admin', email }` | NULL ou admin selon source |
| `user.disabled` | `{ reason: 'no_memberships' \| 'manual' }` | NULL ou admin |
| `user.reactivated` | `{ reason }` | admin |

`activity_events` reste inchangé — son rôle reste l'affichage timeline issue-centric (SSE + page détail). L'audit_log est platform-wide et orthogonal.

---

## 3. Synchronisation GitLab → memberships locaux

### Service `Autodev::GitlabMembershipSync`

Vit dans `app/services/autodev/gitlab_membership_sync.rb`. Deux modes d'entrée :

- `for_user!(user)` : sync ciblée d'un user. Appelée au callback omniauth.
- `for_all_users!` : balayage complet. Appelée par le job récurrent.

Algorithme `for_user!` :

```
1. Résoudre user.gitlab_user_id si non posé :
   - GET /users?search=<user.email>
   - Si unique match : stocker user.gitlab_user_id + user.gitlab_username
   - Si 0 ou ≥2 matches : raise UnresolvedGitlabIdentity (audit_log + AccessDenied au login)

2. Pour chaque project dans Project.all :
   - GET /projects/:id/members/all?user_ids=<gitlab_user_id>
     (ou GET /projects/:id/members/all puis filtre côté Ruby si plus rapide selon volumétrie)
   - Si access_level >= 40 → role local 'owner'
   - Si access_level >= 20 → role local 'contributor'
   - Si access_level == 10 ou pas de membership → no role

3. Réconcilier avec les ProjectMembership existants pour ce user :
   - Diff (project_id, role) côté GitLab vs côté local
   - INSERT les nouveaux (audit_log: membership.granted)
   - UPDATE ceux qui changent de role (audit_log: membership.role_changed)
   - DELETE ceux qui n'existent plus (audit_log: membership.revoked)

4. Si user.memberships.empty? après réconciliation :
   - user.update!(disabled_at: Time.current)
   - audit_log: user.disabled (reason: 'no_memberships')
   - Au callback omniauth, raise AccessDenied
```

### Matching identité Entra ID ↔ GitLab

**Plan par défaut : email.** À la première sync, `GET /users?search=<email>` retourne le match GitLab. Pré-requis : le token autodev doit voir l'email des users via cet endpoint.

**À vérifier avant PR2** : le token autodev (PAT) expose-t-il l'email dans `/users?search=`. Si oui (token créé par un admin GitLab, ou si les users ont leur email en `public_email`), on procède. Sinon :

- **Fallback 1** : matching par convention `prenom.nom@modulotech.fr` ↔ username `prenom.nom`. Strict mais zéro friction si la convention tient.
- **Fallback 2** : champ `gitlab_username` posé manuellement par l'admin dans `bin/rails console`, ou à la première connexion via un formulaire « link your GitLab account ».

Ce point reste en suspens — il n'engage PR1 (audit_log isolé), il bloque seulement PR2.

### Périmètre des projets

Seulement les rows de la table `projects` (peuplées par `autodev:migrate_projects_from_yaml`). Pas de découverte de nouveaux projets côté GitLab. Si l'admin ajoute un projet à `~/.autodev/config.yml` et relance le rake d'import, la prochaine sync inclura le nouveau projet.

### Déclenchement

| Trigger | Quoi | Où |
|---|---|---|
| Callback omniauth | `for_user!(user)` synchrone | `Users::OmniauthCallbacksController#entra_id` |
| Job récurrent quotidien | `for_all_users!` | `SyncGitlabMembershipsJob`, `config/recurring.yml` schedule `0 3 * * *` |
| Rake manuel | `for_all_users!` (cli wrapper) | `lib/tasks/autodev.rake` (`autodev:sync_memberships`) |

Le job hérite du `JobLogger` pour rester compatible avec les workflows existants (cf railsification-postmortem alpha.3).

### Échec API GitLab

Pendant la sync :

- **Users existants en DB** : on garde l'état memberships précédent. Login passe avec le cache. Log warning dans `Rails.logger` + audit_log `user.sync_failed` (action ajoutée si besoin, pas critique au MVP).
- **Users inexistants** (création en cours) : on rejette la création du row User. Le callback omniauth renvoie sur une page d'erreur « accès GitLab indisponible, ressayez plus tard ». Évite de créer un row orphelin avec 0 memberships qui serait disabled juste après.

Distinction faite via try/catch autour du fetch GitLab + branch sur `User.persisted?`.

---

## 4. Gating & visibilité

### `authenticate_user!`

Posé sur `ApplicationController` en PR3 :

```ruby
class ApplicationController < ActionController::Base
  before_action :authenticate_user!
end
```

Devise gère le redirect vers `/users/auth/entra_id` quand non authentifié. Les routes Devise (`/users/auth/*`) ne déclenchent pas le before_action.

`User#active_for_authentication?` override :

```ruby
def active_for_authentication?
  super && disabled_at.nil?
end

def inactive_message
  disabled_at.present? ? :access_revoked : super
end
```

Locale `devise.failure.access_revoked = "Votre accès a été révoqué. Contactez un admin."` ajoutée dans `config/locales/devise.fr.yml` (et `.en.yml`).

### Visibilité hybride

Helper `User#visible_projects` :

```ruby
def visible_projects
  admin? ? Project.all : Project.joins(:project_memberships).where(project_memberships: { user_id: id })
end
```

Tous les controllers qui scopent par projet (DashboardController, ProjectsController, IssuesController, etc.) substituent `Project.all` par `current_user.visible_projects` au PR3. Les Issues sont scopés via `Issue.joins(:project).merge(current_user.visible_projects)` — nécessite que le modèle Issue soit lié à Project par `project_path`. Si la jointure n'existe pas encore proprement (Issue n'a qu'un `project_path` string), PR3 doit l'introduire (`belongs_to :project, foreign_key: :project_path, primary_key: :gitlab_path`).

### Gating de la création

Au callback omniauth, si `for_user!` ne produit aucun membership ≥ Reporter, on disable le user (cf §3). Devise refuse le login dans la foulée.

### CSRF

Le `skip_forgery_protection only: %i[reset transition]` actuel dans `IssuesController` est retiré. Le layout Phlex (`app/components/web/views/layout.rb`) est modifié pour émettre `csrf_meta_tags` + un hidden input dans chaque form reset/transition (`<%= form_with ... %>` côté Rails gère, mais les forms Phlex sont manuels). Concrètement :

- Layout : `meta name='csrf-token' content=<%= request_forgery_protection_token %>`.
- Forms reset/transition : ajout d'un `input type='hidden' name='authenticity_token' value=<%= form_authenticity_token %>`. Helper `csrf_input` à introduire dans `Web::Helpers`.

Coût : ~30 lignes Phlex + tests sur reset/transition (existants à mettre à jour).

### Sign-out

Route Devise standard `delete_user_session_path` (= `/users/sign_out`). Ajout dans la nav (header Phlex) :

- À gauche du logo ou en haut à droite : `current_user.email | Sign out`
- Bouton Sign out = `<button form='signout-form'>` lié à un `<form method='post' action='/users/sign_out'>` avec token CSRF.

---

## 5. Bootstrap & cutover prod

### Rake `autodev:seed_admin`

```ruby
namespace :autodev do
  desc 'Seed an admin user by email. Usage: bin/rails autodev:seed_admin EMAIL=marc@modulotech.fr'
  task seed_admin: :environment do
    email = ENV.fetch('EMAIL')
    user = User.find_or_initialize_by(email: email)
    user.admin = true
    user.save!(validate: false)  # bypass Devise password validation (omniauthable, no password)
    AuditLog.create!(
      resource_type: 'User', resource_id: user.id,
      action: 'user.created', payload: { source: 'seed_admin', email: email }
    )
    puts "Seeded admin: #{user.email} (id=#{user.id})"
  end
end
```

À lancer sur bobette via SSH avant l'activation du gating en PR3 :

```bash
ssh bobette-autodev
sudo -u autodev bin/rails autodev:seed_admin EMAIL=marc@modulotech.fr
```

### Séquence de cutover prod (au moment du PR3)

```
T-1j : merge PR2 + brew release alpha.4 incluant la sync GitLab, sans gating.
       brew upgrade autodev sur bobette → launchd restart.
       SSH bobette : bin/rails autodev:seed_admin EMAIL=…
                     bin/rails autodev:sync_memberships
       Vérifier : SELECT count(*) FROM project_memberships;
                  SELECT email, admin FROM users;
       Tous les users attendus apparaissent (via les memberships GitLab).

T-0  : merge PR3 + brew release alpha.5 (gating actif).
       brew upgrade autodev sur bobette → launchd restart.
       Tester depuis Safari + NetBird : tu es redirigé vers Entra ID.
       Sign-in OK → dashboard visible (admin = tout).
       Demander à un collègue de tester → il voit ses projets seulement.

Rollback : brew install modulotech/tap/autodev@alpha.4 + launchd restart.
           Le gating disparaît, le reste (users, sync, audit_log) reste en place.
```

Pas de migration DB destructive entre alpha.4 et alpha.5 — le rollback est purement code.

---

## 6. Schéma DB récapitulatif

| Migration | Quoi | Quand |
|---|---|---|
| `db/migrate/2026XXXXXXXXXX_create_audit_logs.rb` | Table `audit_logs` | PR1 |
| `db/migrate/2026XXXXXXXXXX_add_admin_to_users.rb` | `users.admin`, `users.gitlab_user_id`, `users.gitlab_username`, `users.disabled_at` | PR2 |
| `db/migrate/2026XXXXXXXXXX_add_project_to_issues.rb` | (Optionnel) `issues.project_id` + backfill depuis `issues.project_path` ↔ `projects.gitlab_path` | PR3 si jointure pas déjà propre |

Pas de touche à `project_memberships` — schéma step 3 suffit.

---

## 7. Plan de livraison — 3 PRs

### PR1 — `audit_log` + actor sur actions manuelles

**Scope.** Création de la table `audit_logs`, modèle `AuditLog`, helper `record_audit!(...)`. Câblage sur `IssuesController#reset` + `IssuesController#transition` (actor = `current_user`, qui est NULL pour l'instant car pas d'auth — colonne nullable, on instrumente). Câblage du callback AASM `after_all_transitions` pour les transitions automatiques (actor toujours NULL). Pas de UI d'affichage en PR1.

**Fichiers attendus.**

- `db/migrate/.._create_audit_logs.rb`
- `app/models/audit_log.rb`
- `app/services/audit.rb` (helper module ou classe utilitaire `Audit.record!(resource:, action:, actor:, payload:)`)
- `app/controllers/issues_controller.rb` (appel à `Audit.record!` sur reset + transition)
- `app/models/issue.rb` (callback AASM)
- `test/models/audit_log_test.rb`, `test/services/audit_test.rb`
- `CHANGELOG.md` `[Unreleased]`

**Test plan.**

- POST `/issues/:id/reset` ⇒ 1 row audit_log, actor_id NULL (auth pas encore), action `issue.reset_manual`.
- POST `/issues/:id/transition` ⇒ idem, action `issue.transition_manual`.
- Transition AASM auto déclenchée par AutodevPollJob ⇒ row audit_log, action `issue.transition_auto`, actor_id NULL.
- Pas de régression sur `bundle exec rake test` (452 tests).

**Risque.** Très faible — table additive, pas de gating.

---

### PR2 — `GitlabMembershipSync` + admin + rake + job quotidien

**Scope.** Colonne `admin` sur User (+ `gitlab_user_id`, `gitlab_username`, `disabled_at`). Service `Autodev::GitlabMembershipSync` (modes `for_user!` + `for_all_users!`). Câblage au callback omniauth (sync à la connexion). Job `SyncGitlabMembershipsJob` + entry `config/recurring.yml`. Rake `autodev:seed_admin` + `autodev:sync_memberships`. **Pas d'activation de `authenticate_user!`** — le dashboard reste ouvert.

**Bloqueur.** Vérifier que le token autodev voit l'email des members via `/users?search=`. Si non, branche fallback (cf §3).

**Fichiers attendus.**

- `db/migrate/.._add_admin_to_users.rb`
- `app/models/user.rb` (admin?, active_for_authentication?, visible_projects)
- `app/services/autodev/gitlab_membership_sync.rb`
- `app/jobs/sync_gitlab_memberships_job.rb`
- `app/controllers/users/omniauth_callbacks_controller.rb` (appel à `GitlabMembershipSync.for_user!`)
- `config/recurring.yml` (entry `sync_gitlab_memberships`)
- `lib/tasks/autodev.rake` (`seed_admin`, `sync_memberships`)
- `app/controllers/admin/users_controller.rb` + vue Phlex `app/components/web/views/admin/users.rb` (read-only : liste users × memberships)
- Tests : `test/services/gitlab_membership_sync_test.rb` (stub `Gitlab.client`), `test/jobs/sync_gitlab_memberships_job_test.rb`, `test/models/user_admin_test.rb`
- `CHANGELOG.md` `[Unreleased]`

**Test plan.**

- Boot Rails, lancer rake `autodev:seed_admin EMAIL=test@example.com` ⇒ row User créée avec admin: true.
- Stub GitLab API (membres d'un projet test) + appel `GitlabMembershipSync.for_user!(user)` ⇒ rows `project_memberships` créées avec les bons rôles + audit_log entries.
- Sync 2ème fois après changement GitLab (Maintainer ⇒ Owner) ⇒ role updated + audit_log `membership.role_changed`.
- Sync après retrait GitLab ⇒ membership détruit + audit_log `membership.revoked`.
- User Guest partout ⇒ disabled_at posé + audit_log `user.disabled`.
- Page admin `/admin/users` : 200, liste les users + leurs projets. Refus 403 pour non-admin (le before_action admin? est posé même si authenticate_user! global ne l'est pas encore).

**Risque.** Modéré. Le matching email/identité est le point sensible. Côté DB, additif uniquement.

---

### PR3 — Gating actif + UI sign-out + visibilité par membership + CSRF

**Scope.** `before_action :authenticate_user!` posé sur `ApplicationController` (et levé sur Devise routes). Refonte du layout Phlex pour émettre csrf_meta_tags + bouton Sign out + indicateur "logged in as X". Forms reset/transition migrés pour porter le CSRF token. Visibilité par membership : `current_user.visible_projects` substitué à `Project.all` dans tous les controllers concernés. Issue scopée par membership (introduit `belongs_to :project` sur Issue si besoin).

**Fichiers attendus.**

- `app/controllers/application_controller.rb` (`before_action :authenticate_user!`)
- `app/components/web/views/layout.rb` (csrf_meta_tags, sign-out, indicateur user)
- `app/components/web/views/components/*.rb` (forms reset/transition avec csrf_input)
- `app/controllers/{dashboard,projects,issues,errors,list,stream}_controller.rb` (scope par `current_user.visible_projects`)
- `app/models/issue.rb` (`belongs_to :project, foreign_key: :project_path, primary_key: :gitlab_path` si introduit)
- `app/helpers/web/helpers.rb` (`csrf_input` helper)
- `config/locales/devise.{fr,en}.yml` (message `access_revoked`)
- Tests : routes refusent l'anonyme (302 → /users/auth/entra_id), routes acceptent un user loggé, visibilité hybride respectée (admin voit tout, non-admin voit ses projets), reset/transition demandent CSRF token.
- `CHANGELOG.md` `[Unreleased]`

**Test plan.**

- Curl sans session sur `/` ⇒ 302 vers `/users/auth/entra_id`.
- Curl sans CSRF sur `POST /issues/:id/reset` après login ⇒ 422.
- Login en tant qu'admin ⇒ voit tous les projets sur `/projects` et `/`.
- Login en tant que non-admin avec memberships sur 1 projet ⇒ voit seulement ce projet.
- User disabled ⇒ login refusé avec message localisé.

**Risque.** Le plus élevé des trois — c'est le moment où on peut se locker dehors. Mitigé par le séquencement (seed_admin a déjà tourné en PR2, on a la garantie qu'au moins un user peut entrer).

---

## 8. Pièges identifiés

| Piège | Mitigation |
|---|---|
| Token autodev ne voit pas l'email des members GitLab | Décision en suspens — vérifier le scope avant PR2. Fallback documenté en [§3](#matching-identité-entra-id--gitlab). |
| Sync au callback omniauth qui dure > timeout HTTP | Si N projets large + GitLab lent, scinder en : login immédiat sur cache, sync async via job déclenché au callback. À surveiller au PR2 — pas un bloqueur tant que N < ~30 projets. |
| Premier seed_admin oublié avant activation du gating | Le séquencement de cutover en deux releases (PR2 avant PR3) interdit l'oubli — le gating ne s'active qu'au PR3. |
| Sync downgrade un admin en non-admin par mégarde | `admin: true` n'est PAS touché par la sync — seulement les memberships projet. L'admin reste admin même sans memberships. |
| Un user perd son accès GitLab pendant une session active | Sa session reste valide jusqu'au sign-out (Devise 2 semaines). Au prochain login, gating le refuse. Acceptable au MVP. Hardening possible : invalider la session à chaque sync qui désactive un user. |
| `belongs_to :project` sur Issue rate les rows orphelines (issues d'un projet retiré de `projects`) | Au PR3, faire un check pré-migration : `Issue.where.not(project_path: Project.pluck(:gitlab_path))`. Si non vide, soit on ré-import, soit on les laisse non-visible (admin only). |
| CSRF token côté Phlex form non émis ⇒ 422 généralisé | Tests d'intégration sur reset + transition obligatoires en PR3. Helper `csrf_input` centralisé évite l'oubli côté view. |
| Test suite passe au login Entra ID en CI | Devise.test_mode déjà câblé pour le step 3 (cf railsification-postmortem §4 sur le piège OmniAuth.config.test_mode). On reste sur l'approche du step 3 — controller tests stubent `User.from_omniauth`, pas d'intégration full SSO. |
| Audit_log payload jsonb sur SQLite | SQLite n'a pas de jsonb natif mais accepte json (text). AR sérialise/désérialise transparent via `t.jsonb` qui devient `t.text` côté schema dump. Vérifier la migration côté SQLite. |

---

## 9. Décisions verrouillées (récapitulatif rapide)

| Sujet | Décision |
|---|---|
| Admin | `User#admin: boolean`, plateforme-wide |
| Source des memberships | Sync GitLab (autoritaire, ADD + REMOVE) |
| Mapping access | ≥40 → owner, 20-30 → contributor, 10 → exclu |
| Matching identité | Email (à confirmer après vérif token), fallback username manuel |
| Sync timing | Callback omniauth + job quotidien `0 3 * * *` |
| Scope projets | Table `projects` actuelle uniquement |
| Bootstrap | `autodev:seed_admin EMAIL=...` (pas d'auto-admin du 1er user) |
| Visibilité | Hybride : admin tout, autres via memberships |
| User révoqué | `disabled_at` posé, login refusé |
| Sync failure | Users existants OK (cache), refus de création des nouveaux |
| CSRF | Re-activé, refonte layout Phlex |
| Audit | Table dédiée `audit_log` (séparée de `activity_events`) |
| Tracé dans audit | Actions manuelles + transitions auto + lifecycle memberships + lifecycle users |
| UI admin | `/admin/users` read-only en PR2 |
| Découpage | PR1 audit → PR2 sync + admin → PR3 gating + visibilité + CSRF |

---

## 10. Références

- [`autospec.md`](autospec.md) §J (rôles & permissions) — base du modèle owner/contributor.
- [`autospec.md`](autospec.md) §K (notifications) — explique pourquoi pas d'email/Teams.
- [`railsification-postmortem.md`](railsification-postmortem.md) — alpha.3 JobLogger, à reprendre pour le job de sync.
- [`archive/railsification-handoff.md`](archive/railsification-handoff.md) §4 — pièges Devise + omniauth + CSRF déjà rencontrés.
- [`../CLAUDE.md`](../CLAUDE.md) — architecture Rails actuelle, état des routes du dashboard.
