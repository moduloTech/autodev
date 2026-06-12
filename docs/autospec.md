# AutoSpec — Synthèse de cadrage

**Date :** 18 mai 2026
**Source :** interview produit à partir du compte-rendu de réunion (Matthieu, Julien, Rémi) et des design handoffs `design/` (v1) + `design/spec_update/` (v2).

Ce document fige les décisions prises pendant le cadrage AutoSpec et le chantier de railsification qui l'accompagne. Il liste aussi les zones grises restantes et l'ordre d'attaque recommandé.

---

## A. Décisions actées

### Posture produit & design

- **Chat reste first-class** : la conversation avec Autodev demeure le geste central du produit. L'éditeur markdown ajouté en v2 est un *mode rapide* pour power users qui permet d'atteindre le même résultat — pas un pivot, une inclusion.
- **Captures (drag-drop)** = feature métier : les CSMs collent aujourd'hui des données clients, des messages d'erreur, des parcours utilisateurs, parfois des mockups du résultat attendu. La conversation seule ne couvre pas ces cas.
- **Libellés d'état à reformuler en langage métier** : décrire *ce qu'Autodev fait* (`vérification que la fonctionnalité marche`) plutôt que l'étape technique (`vérification auto`). La table `STATES.md` doit être revisitée.

### Workflow d'approbation

- **Authentification Microsoft 365 SSO** — le même compte qui sert pour GitLab.
- **Ownership projet en DB** (pas dans `config.yml`, pas inféré depuis GitLab).
- **Validation obligatoire de tous les owners, y compris l'auteur** — choix motivé par la simplicité du workflow technique ET la protection produit (forcer une relecture).
- **MVP UI** : encart dans le dashboard listant les tickets à approuver pour l'owner connecté. Pas d'inbox dédiée, pas de notifications externes pour l'instant.
- **Rejet** : un owner qui rejette doit commenter la raison. Le ticket sort alors de la file d'approbation des autres owners ; l'auteur reprend la main dans l'interface de création.
- **"Mode autonome client"** mentionné dans le CR : oublié pour le MVP.

### Architecture

- **Railsification dans le même repo**, progressive.
- **Solid Queue** pour le polling, en tâche récurrente.
- **`bin/autodev` devient un superviseur** : boot Rails server + Solid Queue worker + sidecars. Distribution Brew préservée — le script reste le point d'entrée d'installation.
- **`danger-claude` et `mr-review` restent des formulas Brew séparées**, indépendantes.
- **Devise + omniauth Azure AD** pour le SSO Microsoft 365.
- **Locales** : migration complète des hashes Ruby (`NOTIFICATION_TEMPLATES`, `ACTIVITY_TEMPLATES`, `WEB_TEMPLATES`) vers `config/locales/*.yml`, fichiers séparés par thème. FR + EN obligatoires (la stricte règle de localisation héritée de l'actuel Autodev s'applique aussi à AutoSpec malgré des designs 100% FR).
- **`config.yml`** : ne contient plus que les settings root (token GitLab, intervals, web bind/port). Toute la configuration projet passe en DB.

### Modèle de données (nouvelles tables)

| Table | Rôle |
|---|---|
| `users` | Compte Microsoft 365 |
| `projects` | Métadonnées projet (path GitLab, slug, locale par défaut, …) |
| `project_app_commands` | `belongs_to :project`, `category` enum (`setup`, `test`, `lint`, `run`), `command` JSON, `port` nullable |
| `project_memberships` | `user_id` + `project_id` + rôle (`contributor` ou `owner`) |
| `autospec_messages` | Historique conversationnel (role, content, tool_calls JSON), `belongs_to :autospec_draft` |
| `autospec_drafts` | N drafts par user, état du futur ticket (titre, markdown, meta chips, attachments) |
| `autospec_attachments` | Captures liées à un draft |

Exemple de contenu `project_app_commands` (chaque ligne = une row) :

```json
[
  { "category": "setup", "command": ["bundle", "install"] },
  { "category": "setup", "command": ["yarn", "install"] },
  { "category": "test",  "command": ["bundle", "exec", "rspec"] },
  { "category": "run",   "command": ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"], "port": 3000 }
]
```

### Modèle Claude

- **API Anthropic + SDK Ruby** pour AutoSpec — pas la CLI `claude -p -r`.
  - Profil d'usage (court, bursty, interactif) incompatible avec le cold start Docker de `danger-claude`.
  - Quota partagé avec AutoDev = goulot doublé sur le siège Team (pas d'API `/usage` pour anticiper).
  - Prompt caching impossible à exploiter via la CLI.
- **Prompt caching** sur système prompt + contexte projet stable (TTL 5 min couvre une session CSM typique).
- **Streaming SSE** côté Rails (`ActionController::Live` ou Rack hijack — ActionCable est overkill pour du one-way LLM streaming). **Décision à revalider à l'implem AutoSpec** : l'usage AutoDev a fait apparaître une limitation de threading (1 thread Puma parqué par onglet, saturation du pool si les morts client ne sont pas détectées tôt) — détails et critères de décision en section L.
- **Sonnet 4.6** pour la conversation principale, **Haiku 4.5** pour les quick chips (`reformule plus court`, `propose un titre alternatif`).
- **AutoDev reste sur Team** le temps qu'AutoSpec se stabilise. La migration AutoDev → API est explicitement parquée dans le CR (post-bêta).
- **Threads per-user** : un thread = un CSM. Pas de collaboration multi-CSM sur un même draft.

### Insertion des suggestions Autodev dans le brouillon

- **4 tools dédiés** côté SDK Anthropic : `propose_markdown_patch` (par défaut), `propose_full_rewrite`, `propose_title`, `propose_meta_change`. Schémas et flow complets en section G.
- **Application côté client** : le modèle n'exécute pas les tools, l'UI surface des boutons que le CSM applique manuellement.
- **Tool_results synthétiques** rapportant au modèle si chaque suggestion a été appliquée — feedback strict pour adapter les tours suivants.

### Import GitLab d'un ticket existant

- **Very-nice-to-have**, livré en dernier mais inclus pour le pilote.

---

## B. Zones grises restantes

Questions implicites non tranchées pendant l'interview, à arbitrer avant ou pendant l'implémentation.

1. ~~**Cycle de vie post-création** d'un draft~~ → tranchée, voir section E ci-dessous.
2. ~~**Stockage des attachments**~~ → tranchée, voir section F ci-dessous.
3. ~~**Notifications aux owners**~~ → tranchée, voir section K ci-dessous.
4. ~~**Notifications inverses**~~ → tranchée, voir section K ci-dessous.
5. ~~**Granularité des rôles**~~ → tranchée, voir section J ci-dessous.
6. ~~**Migration des données YAML existantes**~~ → tranchée, voir section H ci-dessous.
7. ~~**Coexistence pendant la railsification**~~ → tranchée, voir section D ci-dessous.
8. ~~**Format précis des `tool_calls` Autodev**~~ → tranchée, voir section G ci-dessous.
9. ~~**Refonte du vocabulaire des labels**~~ → tranchée, voir section I ci-dessous.

---

## C. Ordre d'attaque recommandé

Logique de dépendances. À ajuster selon la timeline (qui est traitée hors de ce document).

1. **Squelette Rails** dans le repo : Gemfile, `app/`, `config/`, routes minimales, ActiveRecord branché sur le SQLite existant.
2. **Modèles core** : `User`, `Project`, `ProjectAppCommand`, `ProjectMembership`. Migration `issues` Sequel → ActiveRecord (conserver la gem AASM, qui s'intègre aussi bien à AR).
3. **Auth Devise + omniauth Azure AD** + table sessions.
4. **Rake idempotent d'import** : YAML existant → tables `projects` + `project_app_commands` (cf section H, exécuté manuellement en phase C).
5. **Réécriture poller en Solid Queue récurrente** (`AutodevPollJob`).
6. **`bin/autodev` superviseur** : démarre Rails server + Solid Queue worker en parallèle.
7. **Migration locales** : `lib/autodev/locales/*.rb` → `config/locales/*.yml` thématiques.
8. **Port des vues Phlex** existantes vers Rails (Phlex reste utilisable dans Rails) + refonte des libellés en langage métier.
9. **Backend AutoSpec** : tables `autospec_*`, service `AutospecChat` autour du SDK Anthropic, endpoint SSE.
10. **Frontend AutoSpec** : portage de `reference/screen-chat-spec.jsx` vers Rails (ERB + Stimulus ou Phlex + Turbo, à trancher). Drag-drop attachments via ActiveStorage.
11. **Workflow approbation** : tables `project_memberships` mises en service, encart dashboard, transitions de validation côté `Issue`, gestion des labels GitLab add/remove.
12. **Import GitLab d'un ticket existant** (dernier).

---

## D. Coexistence pendant la railsification

Approche retenue : **strangler fig en 3 phases sur DB SQLite partagée**. Sinatra+Sequel et Rails+ActiveRecord cohabitent dans le même process pendant la transition, sans cutover big-bang. La migration progresse fonctionnalité par fonctionnalité ; seul le passage du poller (phase C) constitue un moment de bascule sensible.

### Phase A — Rails s'ajoute sans rien casser

- Ajout de `Gemfile` + `Gemfile.lock` à la racine. `bin/autodev` reste en `bundler/inline` pour cette phase.
- `config/application.rb`, `config/database.yml` pointent sur le **même fichier SQLite** que Sinatra.
- `bin/rails db:schema:dump` pour capturer le schéma existant sans le modifier.
- Modèles ActiveRecord (`Issue`, `ActivityEvent`) reflètent les tables existantes. AASM bascule de l'adapter Sequel vers l'adapter ActiveRecord (changement de classe parente).
- **Aucune nouvelle table créée**, aucune migration AR jouée.
- En prod : `bin/autodev` continue exactement comme avant. Rails dispo via `bin/rails console` pour inspection.

Validation : ouvrir une console Rails, comparer les comptages à ceux du dashboard Sinatra. Parité lecture acquise. Risque ≈ zéro.

### Phase B — Rails sert des routes en parallèle de Sinatra

- **Rails monte Sinatra en middleware** (`config.middleware.use Autodev::Web::Server`). Un seul serveur, un seul port, Rails délègue à Sinatra les routes pas encore portées.
- Le poller reste dans le process, inchangé.
- Routes portées progressivement vers Rails : `GET /issues/:id`, puis `/projects/:slug`, puis le SSE, etc. Vues Phlex réutilisables telles quelles (Phlex est framework-agnostic).
- Nouvelles routes AutoSpec créées directement côté Rails (greenfield, pas de version Sinatra).
- **Devise + omniauth Azure AD** activé côté Rails. Les routes Sinatra restantes continuent à fonctionner en localhost-only / Netbird sans auth (état actuel).
- Locales : `t_web` côté vues Sinatra encore servies, `I18n.t` côté vues Rails portées. Migration clé par clé au moment du portage.

Risque modéré. Point de vigilance : le pool Sequel actuel est `max_connections: 1` (cf. `lib/autodev/database.rb:86`, choix explicite anti-`SQLITE_BUSY`). ActiveRecord ouvrira son propre pool (5 par défaut) sur le même fichier ; le `busy_timeout` déjà actif absorbe la contention, mais il faut **fixer le pool AR à une valeur basse (1-2)** pour rester cohérent avec le contrat actuel, au moins pendant la coexistence.

### Phase C — Cutover du poller, décommissionnement Sinatra

Moment risqué de la migration, à concentrer sur une fenêtre courte.

- Migrations Rails créent les nouvelles tables : `users`, `projects`, `project_app_commands`, `project_memberships`, `autospec_*`.
- Rake one-shot `autodev:migrate_projects_from_yaml` popule `projects` + `project_app_commands` à partir du `~/.autodev/config.yml` existant.
- Le poller est réécrit en `AutodevPollJob` Solid Queue (recurring).
- `bin/autodev` devient le superviseur final : Rails server + Solid Queue worker + sidecars (Chrome MCP, etc.). `bundler/inline` remplacé par `bundle exec`.
- `lib/autodev/web/` (Sinatra) supprimé. `lib/autodev/poller.rb` aussi (logique portée dans le job, pas jetée).
- Release Brew majeure, changelog explicite, snapshot SQLite avant cutover (`cp` du fichier).

### Phase D — AutoSpec

Construit nativement sur Rails. Pas de coexistence à gérer.

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| `bundler/inline` incompatible avec Rails | Conservé en phase A, abandonné au début de phase B |
| WAL mode + `max_connections: 1` côté Sequel vs pool AR par défaut à 5 | Forcer pool AR à 1-2 en `database.yml` pendant la coexistence ; `busy_timeout` déjà actif |
| AASM Sequel vs ActiveRecord adapter | Une ligne de modèle, AASM gère les deux |
| `schema_migrations` créée par AR | Ignorée par Sequel, aucun conflit |
| `Web::EventBus` (pub/sub in-process pour SSE) | Conservé en phase B, remplacé par `ActionController::Live` + bus simple en phase C |
| Sessions Devise sur cookie | Pas de conflit : Sinatra actuel n'utilise pas de session |

---

## E. Cycle de vie d'un draft AutoSpec

Approche retenue : **conservation indéfinie, transition d'état, pointeur GitLab**. Un draft n'est pas un brouillon jetable — c'est l'artefact qui contient la chaîne de raisonnement qui a produit le ticket, donc une valeur métier qu'on conserve. Une fois le ticket GitLab créé, le draft passe en lecture seule avec un pointeur, jamais purgé.

### États et transitions

```
                      ┌──────────────┐
                      │  drafting    │  ← création, auteur édite librement
                      └──────┬───────┘
                             │ auteur clique « Créer le ticket »
                             │ (iteration += 1)
                             ▼
                      ┌──────────────────┐
                ┌─────┤ pending_approval │  ← lecture seule pour tous, dans encart owner
                │     └──────┬───────────┘
   rejet d'un  │             │ tous les owners approuvent à l'itération courante
   owner ou   │             │
   rétractation│            ▼
                │     ┌──────────────┐
                ▼     │  submitted   │  ← ticket GitLab créé, pointeur stocké
         ┌──────────┐ └──────────────┘
         │ rejected │       (terminal, lecture seule)
         └────┬─────┘
              │ auteur reprend
              ▼
         ┌──────────────┐
         │  drafting    │  ← itération inchangée tant qu'on n'a pas resubmit
         └──────────────┘
```

**Gel total en `pending_approval`** : ni l'auteur ni les owners ne peuvent modifier le draft. Pour éditer, l'auteur doit **rétracter explicitement**, ce qui invalide les approvals déjà reçus pour cette itération. Process clean, traçabilité intacte.

### Schéma

```ruby
create_table :autospec_drafts do |t|
  t.references :user, null: false, foreign_key: true       # auteur
  t.references :project, null: false, foreign_key: true
  t.integer :status, null: false, default: 0               # enum drafting/pending_approval/rejected/submitted
  t.integer :current_iteration, null: false, default: 0    # incrémenté à chaque drafting→pending_approval
  t.string :title
  t.text :markdown
  t.jsonb :meta_chips                                      # type, priority, assignee, tags
  t.string :destination                                    # 'human' | 'autodev', défini à la soumission (cf section J)

  # Renseignés à la soumission finale
  t.datetime :submitted_at
  t.integer :gitlab_issue_iid
  t.string :gitlab_issue_url

  t.timestamps
end

create_table :autospec_messages do |t|
  t.references :autospec_draft, null: false, foreign_key: true
  t.string :role, null: false                              # user | assistant | tool
  t.text :content
  t.jsonb :tool_calls                                      # suggestions structurées
  t.timestamps
end

create_table :autospec_attachments do |t|
  t.references :autospec_draft, null: false, foreign_key: true
  # has_one_attached :file via ActiveStorage (cf zone 2)
  t.timestamps
end

create_table :autospec_approvals do |t|
  t.references :autospec_draft, null: false, foreign_key: true
  t.references :user, null: false, foreign_key: true       # owner qui agit
  t.integer :iteration, null: false                        # snapshot du current_iteration au moment de l'action
  t.string :action, null: false                            # approved | rejected
  t.text :reason                                           # obligatoire si rejected
  t.datetime :acted_at, null: false
end

add_index :autospec_approvals, %i[autospec_draft_id user_id iteration], unique: true
```

Pas de table `autospec_threads` : le thread *est* le draft. `autospec_messages.belongs_to :autospec_draft`. Reflète la réalité fonctionnelle (un draft = une conversation).

### Sémantique de `current_iteration`

- Default `0` à la création (jamais soumis).
- Incrémenté de 1 à chaque transition `drafting → pending_approval`.
- Les `autospec_approvals` figent l'itération au moment de l'action (audit trail).
- Encart owner : `drafts WHERE status = pending_approval AND id NOT IN (SELECT draft_id FROM approvals WHERE iteration = drafts.current_iteration AND user_id = current_owner AND action = 'approved')`.
- Rétractation / rejet ne décrémente jamais `current_iteration`. Resubmit incrémente.

### Visibilité

| Acteur | Voit quoi |
|---|---|
| Auteur | Tous ses drafts, tous statuts (interface "mes brouillons") |
| Owner du projet | Drafts du projet en `pending_approval` (file d'approbation à l'itération courante non encore approuvée par lui) + drafts `submitted` du projet (historique). Matrice complète en section J. |
| Owner ayant rejeté | Continue à voir le draft historiquement, mais plus dans la file d'approbation tant qu'on reste sur la même itération |
| Contributor (non-auteur) | Ne voit pas les drafts d'autrui — chaque draft est privé jusqu'à `submitted` |
| Dev (humain) | Pas d'accès direct au MVP. Lien depuis la page issue d'Autodev possible en V2. |
| Autodev (machine) | Idem MVP. Accès possible en V2 comme contexte d'implémentation. |

### Rétention

**Aucune purge automatique.** SQLite + textes courts + drafts à la dizaine/centaine par CSM = négligeable même sur 2 ans d'usage. L'archive a une valeur produit (retrouver le ticket sur un bug ancien). Si la taille devient un problème (improbable), un job de soft-delete sur les `submitted` antérieurs à N mois pourra être ajouté.

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| Issue GitLab supprimée après soumission | Pointeur orphelin. UI affiche "ticket d'origine introuvable" si l'API renvoie 404, pas de crash. |
| Auteur tente d'éditer un draft `submitted` | Interdit côté UI (lecture seule). Bouton "Voir sur GitLab" remplace "Créer". |
| Resubmit massif après rejets répétés | `iteration` croît, audit trail intact, aucun impact technique. |
| Draft abandonné depuis longtemps en `drafting` | Reste visible dans "mes brouillons", action "supprimer" manuelle disponible. Pas d'auto-archive. |
| Titre modifié sur GitLab après création | `title` du draft devient stale. Acceptable — GitLab est source de vérité post-soumission. |
| Owner qui rétracte son approbation après l'avoir donnée | Hors scope MVP. Une fois approuvé à l'itération N, c'est figé pour cette itération. |

---

## F. Stockage des attachments

Approche retenue : **hybride ActiveStorage local pendant la rédaction + upload GitLab à la soumission**. Les attachments ont deux vies (rédaction/approbation côté AutoSpec, ticket vivant côté GitLab) ; aucune solution pure ne couvre les deux proprement.

### Flux à deux temps

**Pendant `drafting` et `pending_approval`**

- Drop image dans l'UI → `POST /autospec_attachments` → `ActiveStorage::Blob` créé via `has_one_attached :file`.
- Stockage local sur disque Bobette (`config.active_storage.service = :local`, `storage/` à la racine Rails).
- UI sert des **URLs signées locales** avec expiration courte (5 min).
- Visibilité : `current_user.id == draft.user_id || current_user.owner_of?(draft.project)`.

**Au moment de la soumission**

Service `AutospecGitlabSubmitter` :

1. `gitlab.create_issue(project, title, draft.markdown, ...)` — création initiale.
2. Pour chaque attachment : `blob.download` puis `gitlab.upload_file(project_id, payload, filename:)` → retourne `{ url:, markdown:, alt: }`.
3. **Réécriture du markdown** : les URLs signées locales référencées inline dans le markdown sont substituées par les URLs GitLab retournées.
4. **Section "Captures" appendée** uniquement avec les attachments qui ne sont *pas* déjà référencés inline (option (b) — pas de redondance dans la description GitLab).
5. `gitlab.update_issue(..., description: final_markdown)`.
6. `draft.update!(status: :submitted, gitlab_issue_iid:, gitlab_issue_url:, submitted_at:)`.

Toute l'opération est transactionnelle : si l'upload d'un attachment ou la mise à jour échoue, le draft reste en `pending_approval` et l'auteur est notifié. Pas de demi-soumission.

**Les blobs ActiveStorage restent en place** après soumission — cohérent avec la politique de conservation indéfinie de la section E. L'archive du draft reste complète même si GitLab supprime ses uploads.

### Pourquoi pas pure GitLab uploads

- Uploads orphelins dans le projet GitLab pendant la rédaction (pas de ticket pour les héberger formellement).
- Visibilité owner forcerait un rebond UI/GitLab inutile.
- Resubmit après rejet multiplie les orphelins.

### Pourquoi pas S3

- Volume attendu faible (drafts × ~5 captures × ~500KB sur 1-2 ans = quelques GB).
- Évite débat conformité (données clients vers tiers).
- Pas de nouvelle dépendance / credentials / billing.
- Swap vers S3 reste trivial via config ActiveStorage si nécessaire plus tard.

### Pourquoi pas ActiveStorage local seul

- URLs `bobette.netbird.../autospec/attachments/...` dans la description GitLab forceraient le VPN pour tout consommateur du ticket (dev externes, intégrations, bots GitLab).
- Couplage ticket GitLab ↔ disponibilité Bobette inacceptable.

### Schéma

```ruby
create_table :autospec_attachments do |t|
  t.references :autospec_draft, null: false, foreign_key: true
  t.timestamps
  # has_one_attached :file via ActiveStorage
end
```

Filename, content_type, byte_size, métadonnées (width/height post-analyze) vivent dans les tables ActiveStorage natives (`active_storage_blobs`, `active_storage_attachments`).

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| Attachment référencé inline ET listé en zone captures | Détection lors de la réécriture (regex sur URL signée locale ou ID blob), section "Captures" finale contient uniquement les non-référencés |
| Upload GitLab échoue pour un attachment | Soumission entière échouée en transaction, draft reste `pending_approval`, notification erreur auteur |
| Image > 10 MB (limite design) | Validation côté ActiveStorage à l'upload, refus immédiat avec message |
| Backup Bobette | `storage/` à inclure dans rsync/snapshot. À documenter dans README ops. |
| Croissance disque | Monitoring `du -sh storage/` via route admin. Pas d'auto-cleanup MVP. |
| Suppression par l'auteur en `drafting` | `attachment.destroy` purge le blob ActiveStorage. Pas de soft-delete. |
| Paste depuis clipboard (Cmd+V) | Même flow que drag-drop, géré côté UI |
| URLs signées expirant pendant une session longue | TTL court (5 min) suffit pour le rendering, ActiveStorage régénère à chaque request |

---

## G. Format des suggestions Autodev (tool_calls)

Approche retenue : **mécanisme tool use natif d'Anthropic, 4 outils dédiés, application côté client**. Les "tools" ne sont pas exécutés par le modèle — ce sont des actions UI proposées au CSM via des boutons. Cette inversion impacte la gestion des `tool_results` (synthétiques, voir plus bas).

### Les 4 outils

| Tool | Usage | Notes |
|---|---|---|
| `propose_markdown_patch` | Modifications chirurgicales (ajout, remplacement, création de section). Cas par défaut, attendu ~90 % du temps. | `operation` enum : `insert_after_heading`, `replace_section`, `append_to_end`, `create_section`. |
| `propose_full_rewrite` | Refonte complète du markdown. Réservé aux refontes structurelles, `rationale` obligatoire. | À décourager dans la description du tool ET dans le system prompt. |
| `propose_title` | Changement de titre uniquement. | Trivial. |
| `propose_meta_change` | Type, priorité, tags. Plusieurs changements groupables en un appel. | Pas d'`assignee` au MVP — choix humain du CSM. |

Schémas JSON complets dans le fichier d'origine de cette synthèse (voir l'analyse en chat). Chaque tool inclut un champ `summary` ou `rationale` court (≤ 50 caractères pour `summary`) qui pilote le label du bouton UI.

### Application côté serveur

Quand le CSM clique sur un bouton de suggestion : `POST /autospec_drafts/:id/apply_suggestion` avec `{ message_id, tool_use_id }`.

Service `AutospecSuggestionApplier` :
- Localise le `tool_call` correspondant dans `autospec_messages.tool_calls`.
- Idempotent : si `applied_at` déjà rempli, refuse (`AlreadyApplied`).
- Applique le patch selon le type de tool.
- Stamp `applied_at` sur le tool_call et sauvegarde le message.

Edge case `target_heading` introuvable (typo, casse, section supprimée entre-temps) : recherche tolérante (case-insensitive + trim), fallback `append_to_end` avec toast utilisateur "section non trouvée, ajouté en fin".

### Persistance dans `autospec_messages.tool_calls`

JSON column stockant les blocs `tool_use` bruts du modèle, enrichis d'un `applied_at` :

```json
[
  {
    "type": "tool_use",
    "id": "toolu_01abc",
    "name": "propose_markdown_patch",
    "input": {
      "operation": "create_section",
      "target_heading": "## Cas limites",
      "content": "- L'utilisateur revient en arrière après validation\n- ...",
      "summary": "Ajouter 3 cas limites"
    },
    "applied_at": "2026-05-18T14:23:11Z"
  }
]
```

### Tool results synthétiques (point critique)

L'API Anthropic exige qu'un `tool_use` soit suivi d'un `tool_result` du même `id` dans l'historique. Comme les tools sont appliqués côté client (pas par le serveur), on construit des **tool_results synthétiques** lors de la construction de l'historique pour la requête suivante :

```ruby
def synth_tool_result(tool_call)
  {
    type: 'tool_result',
    tool_use_id: tool_call['id'],
    content: if tool_call['applied_at']
               "Applied by user at #{tool_call['applied_at']}."
             else
               "User has not applied this suggestion."
             end
  }
end
```

Feedback **strict** : on dit au modèle factuellement si chaque suggestion a été appliquée ou pas. Le modèle s'adapte naturellement ("l'utilisateur n'a pas pris ma suggestion → soit hors sujet, soit il préfère continuer la discussion"). Pas de markdown courant inclus dans le tool_result — il est déjà dans le system prompt cacheable, inutile de gonfler chaque tour.

Si le CSM tape ensuite un message, le `content` du prochain user turn est : `[tool_results..., {type: 'text', text: 'le message'}]`.

### Streaming & UI

- Le SDK Anthropic streame natively (`stream: true`).
- Texte d'abord (raisonnement éventuel), puis `tool_use` blocks à la fin du turn.
- Frontend : effet typing sur le texte, puis rendu des boutons de suggestion à mesure que les `tool_use` arrivent complets.
- **Plusieurs `tool_use` par message acceptés** — chacun rend son bouton, le CSM applique indépendamment.

### System prompt cacheable

Portion stable taggée `cache_control: { type: 'ephemeral' }` :
- Persona Autodev, ton, langue.
- Contexte produit (projet courant, conventions, exemples).
- Instructions explicites sur l'usage des tools (préférer `propose_markdown_patch`, éviter `propose_full_rewrite`, etc.).

Le markdown courant du draft est aussi cachable s'il ne change pas pendant la session — re-injection à chaque turn, le cache hit couvre 90 % des tokens.

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| `target_heading` ne matche pas (typo, casse, espace) | Recherche case-insensitive + trim ; fallback `append_to_end` + toast |
| Plusieurs sections avec même heading | Première occurrence ; limitation documentée |
| Modèle abuse de `propose_full_rewrite` | Description du tool décourageante + instruction system prompt + tracking optionnel du ratio |
| `tool_use` streamé incomplet (timeout, erreur) | Bloc partiel ignoré côté UI, message marqué errored, retry possible |
| Suggestion appliquée deux fois | `applied_at` vérifié serveur, idempotent |
| CSM applique puis revert manuellement | Acceptable MVP — le tool_result reflète le clic, pas l'état final du markdown |
| Coût tokens du system prompt augmente avec les tools | Cache covers it (5min TTL), négligeable après premier turn |

### Hors scope MVP

- Tools d'introspection codebase (`read_file`, `list_files`) : registre AutoDev, pas AutoSpec.
- Suggestions sur attachments (supprimer une capture obsolète) : non critique.
- Multi-tool parallèle modifiant des sections distinctes en un seul turn : techniquement supporté, à valider à l'usage.

---

## H. Migration YAML → DB

Approche retenue : **rake idempotent + dry-run + double backup, exécuté manuellement en phase C avec downtime court**. Le réflexe "one-shot pur" est écarté au profit d'une tâche qui peut être testée sur snapshot avant le cutover réel et ré-exécutée sans dommage si la première passe plante.

### Le rake

`bin/autodev migrate-projects` (wrapper sur la tâche rake `autodev:migrate_projects_from_yaml`) :

- **Idempotent** : `Project.find_or_initialize_by(gitlab_path:)` retrouve les projets existants. `project.app_commands.destroy_all` reconstruit proprement à chaque exécution.
- **Transactionnel** : tout ou rien. Échec en cours → rollback complet.
- **Dry-run** : `DRY_RUN=1` exécute la logique mais rollback la transaction. Affiche le summary attendu sans toucher la DB.
- **Validation pré-write** : un `validate_all!` parcourt tout le YAML en read-only avant le moindre INSERT. Abort propre avec liste des problèmes si données manquantes ou clés inattendues.
- **Summary final** : nombre de projets créés/mis à jour, nombre d'`app_commands` par catégorie, warnings éventuels.

Squelette :

```ruby
namespace :autodev do
  desc 'Migrate per-project config from ~/.autodev/config.yml into projects + project_app_commands'
  task migrate_projects_from_yaml: :environment do
    yaml = YAML.safe_load_file(ENV.fetch('AUTODEV_CONFIG', '~/.autodev/config.yml'))
    projects_yaml = yaml.fetch('projects', {})

    validate_all!(projects_yaml)

    ApplicationRecord.transaction do
      projects_yaml.each do |key, attrs|
        project = Project.find_or_initialize_by(gitlab_path: attrs.fetch('gitlab_path'))
        project.assign_attributes(slug: key, name: attrs['name'] || key, ...)
        project.save!

        project.app_commands.destroy_all
        %i[setup test lint].each do |cat|
          Array.wrap(attrs.dig('app', cat.to_s)).each { |cmd| project.app_commands.create!(category: cat, command: cmd) }
        end
        Array.wrap(attrs.dig('app', 'run')).each do |entry|
          project.app_commands.create!(category: :run, command: entry.fetch('command'), port: entry['port'])
        end
      end
      raise ActiveRecord::Rollback if ENV['DRY_RUN'] == '1'
    end
  end
end
```

### Exécution **manuelle**, pas automatique au boot

Décision : `bin/autodev migrate-projects` est une commande explicite, lancée une fois par l'opérateur pendant le cutover. Pas d'auto-exécution si `projects.empty?` au boot.

Raison : lisibilité opérationnelle. L'opérateur voit le summary, sait que c'est une opération sensible, peut annuler avant que ce soit appliqué. Le coût (une commande à taper) est trivial vs le bénéfice de visibilité.

### Plan de cutover (intégré à la phase C de la railsification)

```
Pré-cutover (la veille ou quelques heures avant) :
  1. Snapshot DB : sqlite3 ~/.autodev/autodev.db ".backup ~/.autodev/autodev.db.pre-c-<ts>"
  2. Copier le YAML : cp ~/.autodev/config.yml ~/.autodev/config.yml.pre-c-<ts>
  3. Sur copie locale, dry-run du rake. Diff manuel des projets attendus.
  4. Toujours en local, exécution réelle, inspection des rows produites.

Cutover (5-15 min de downtime) :
  5. brew upgrade autodev (installe la nouvelle version localement, pas de boot encore).
  6. Boot du nouveau bin/autodev : Rails db:migrate crée les nouvelles tables.
  7. bin/autodev migrate-projects : exécution réelle, vérification du summary.
  8. Démarrage normal : poller Solid Queue lit depuis DB.

Post-cutover :
  9. YAML d'origine reste intact sur disque, ignoré par le nouveau code.
  10. Optionnel : renommer en `config.yml.legacy-projects` pour signaler explicitement.

Rollback (si problème dans la première heure) :
  A. Stop bin/autodev.
  B. brew install modulotech/tap/autodev@<previous>.
  C. Restore DB : cp ~/.autodev/autodev.db.pre-c-<ts> ~/.autodev/autodev.db.
  D. YAML toujours en place, intact.
  E. Restart. Retour à l'état pré-cutover.
```

### Coexistence en phase B

Point de vigilance : pendant la phase B (Sinatra + Rails cohabitent), le poller Sinatra **continue à lire la config projet depuis YAML**. La migration n'a de sens **qu'une fois que le poller lit depuis DB** — donc en phase C, après le swap du poller code.

Donc : pas d'exécution de `bin/autodev migrate-projects` en phase B. Les tables Rails peuvent exister vides, ignorées. Sinon : risque de divergence YAML/DB si quelqu'un édite le YAML pendant que les rows DB sont déjà créées.

### Stripping du YAML après migration

Position MVP : **ne rien faire automatiquement**. Le bloc `projects:` reste dans le YAML mais n'est plus lu par le code Rails. L'opérateur peut renommer manuellement en `.legacy-projects` s'il veut être explicite.

Justification : un seul opérateur (toi) au MVP, risque de confusion faible. Si la confusion devient un vrai problème en équipe étendue, un step "déplacer le bloc projets vers `.legacy-projects`" peut être ajouté au rake plus tard.

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| YAML contient une clé inattendue | Validator strict en pré-pass, abort avec liste des clés non reconnues |
| `gitlab_path` mal formé | Normalisation explicite (trim, lowercase) dans le validator |
| `app.run` sans `command` | Erreur dure, abort migration |
| Re-exec écrase des `project_app_commands` édités via l'UI Rails | Acceptable au MVP — la migration est censée tourner une fois. Documenter. |
| Rake plante à mi-chemin | Transaction AR rollback → état pré-migration restauré |
| Snapshot SQLite corrompu | Utiliser `sqlite3 .backup` plutôt que `cp` (sûr face aux écritures concurrentes) |
| Pas de Postgres test pour le rake en CI | Toute la logique testable contre SQLite en mémoire avec fixtures YAML |

---

## I. Vocabulaire des états (refonte STATES.md)

Décision : **v0 figée en interne maintenant, itération avec le CSM pilote en bêta**. Proposer un table complète avant le pilote, plutôt que de lui demander d'inventer en partant de rien. Coût d'ajustement bêta = trivial (un `*.yml`).

### Principes directeurs

1. Le label décrit *ce qu'Autodev fait*, pas l'étape technique.
2. Le label répond à la question silencieuse du CSM : "où en est ma demande, et est-ce que ça avance ?".
3. Les états où le CSM doit agir doivent l'indiquer sans ambiguïté.
4. "MR" / "demande de fusion" reste tolérable car visible côté GitLab de toute façon.

### Nouvelle table

| État technique | Étiquette courte | Ton | Description |
|---|---|---|---|
| `pending` | En attente | muted | Demande reçue. Autodev démarrera dès qu'un agent est disponible. |
| `cloning` | Préparation | working | Autodev récupère le code du projet pour pouvoir y travailler. |
| `checking_spec` | Compréhension de la demande | working | Lecture de ta description et du contexte du projet pour cadrer le travail. |
| `implementing` | Écriture du code | working | Autodev modifie le code pour répondre à ta demande. |
| `committing` | Sauvegarde | working | Enregistrement des modifications dans le code source. |
| `pushing` | Envoi sur GitLab | working | Push des modifications vers le serveur partagé. |
| `creating_mr` | Ouverture de la demande de fusion | working | Création de la MR pour permettre la relecture. |
| `reviewing` | Relecture du travail | working | Autodev relit ses propres modifications pour repérer ses erreurs. |
| `checking_pipeline` | Test de la fonctionnalité | working | Autodev attend la validation des tests automatiques. |
| `answering_question` | Réponse à une question | working | Un développeur a posé une question, Autodev y répond. |
| `running_post_completion` | Finalisation | working | Dernières actions (notifications, tickets liés). |
| `fixing_discussions` | Application des retours de relecture | working | Autodev intègre les corrections demandées par les relecteurs. |
| `fixing_pipeline` | Correction des tests qui échouent | working | Des tests automatiques sont en échec, Autodev essaie de les corriger. |
| `needs_clarification` | En attente d'une précision de ta part | warn | Autodev ne peut pas continuer sans plus d'information de toi. |
| `done` | Livrée | ok | Demande terminée et fusionnée. |
| `error` | Bloquée, intervention nécessaire | err | Autodev s'est arrêté, un humain doit intervenir. |

Tons inchangés vs l'actuel `STATES.md`. Mapping vers tokens CSS également inchangé (`--work-bg/fg`, `--ok-bg/fg`, etc.).

### Changements majeurs (les plus structurants)

- `Vérifications` → **Test de la fonctionnalité** : répond à la critique "vérification de quoi ?".
- `Question en attente` → **En attente d'une précision de ta part** : transforme un état passif en call-to-action explicite.
- `Échec` → **Bloquée, intervention nécessaire** : neutre et actionnable, pas dramatique.

### Mots à éviter (table étendue)

| Mot technique | Remplacement métier |
|---|---|
| Pipeline | Tests automatiques |
| MR / Merge request | Demande de fusion |
| Commit | Sauvegarde |
| Issue | Demande |
| Auto-revue | Relecture |
| Pipeline rouge | Tests qui échouent |
| Discussions | Retours de relecture |
| Clarification | Précision |
| Post-traitement | Finalisation |
| Spec | Description / Demande |

### Localisation

Migration vers `config/locales/web.fr.yml` (et `web.en.yml` miroir, cf. règle i18n stricte) :

```yaml
fr:
  autodev:
    states:
      pending:
        label: En attente
        description: Demande reçue. Autodev démarrera dès qu'un agent est disponible.
      checking_pipeline:
        label: Test de la fonctionnalité
        description: Autodev attend la validation des tests automatiques.
      # ...
```

Le hash Ruby `STATUS_LABEL_KEYS` actuel (cf. `lib/autodev/web/i18n_helpers.rb`) sera converti pendant la phase de migration des locales (étape 7 de l'ordre d'attaque).

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| Tutoiement ("ta part", "toi") inadapté en contexte B2B très formel | Variante "votre part" possible via locale alternative si feedback CSM en ce sens |
| Description trop longue pour tooltip mobile | Truncate UI au-delà de 80 caractères, version complète dans la page détail |
| Genre grammatical mixe neutre et féminin selon les états | Cohérent à l'oreille — neutre quand on décrit l'action, féminin quand on qualifie la demande |
| "Demande de fusion" est un terme rare en français | OK côté CSM, on conserve "MR" dans la doc technique pour les devs |

---

## J. Rôles & permissions

Deux rôles, avec héritage : **owner = contributor + privilèges supplémentaires**. Pas de table par rôle, une seule `project_memberships` avec colonne `role` enum.

### Définitions

| Rôle | Capacités |
|---|---|
| **Contributor** | Voit le projet dans l'interface. Crée des drafts AutoSpec sur le projet. Soumet des drafts pour approbation. Définit la destination = "dev humain" seulement. |
| **Owner** | Toutes les capacités de contributor. **Valide les drafts** (intervient dans le workflow d'approbation, son vote est requis avec celui des autres owners). **Définit la destination = "AutoDev"** (gate dur). |

L'autorité "envoyer à AutoDev" est un verrou produit volontaire — un contributor seul ne peut pas déclencher du travail AutoDev sans qu'un owner ait pris part au workflow.

### Schéma

```ruby
create_table :project_memberships do |t|
  t.references :user, null: false, foreign_key: true
  t.references :project, null: false, foreign_key: true
  t.string :role, null: false   # 'contributor' | 'owner'
  t.timestamps
end

add_index :project_memberships, %i[user_id project_id], unique: true
```

Un utilisateur ne peut avoir qu'un seul rôle par projet (index unique). Un changement de rôle = `UPDATE`, pas un nouveau row.

### Helpers d'autorisation

```ruby
class User < ApplicationRecord
  has_many :project_memberships

  def role_on(project)
    project_memberships.find_by(project: project)&.role
  end

  def contributor_of?(project)
    role_on(project).present?  # contributor OR owner (héritage)
  end

  def owner_of?(project)
    role_on(project) == 'owner'
  end
end
```

### Matrice de permissions

| Action | Aucun rôle | Contributor (non-auteur) | Contributor (auteur) | Owner (non-auteur) | Owner (auteur) |
|---|---|---|---|---|---|
| Voir le projet | ❌ | ✅ | ✅ | ✅ | ✅ |
| Créer un draft sur le projet | ❌ | ✅ | — | ✅ | — |
| Voir un draft (drafting, rejected) | ❌ | ❌ | ✅ | ❌ | ✅ |
| Voir un draft (pending_approval) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Voir un draft (submitted) | ❌ | ❌ | ✅ | ✅ | ✅ |
| Modifier un draft (en drafting) | ❌ | ❌ | ✅ | ❌ | ✅ |
| Rétracter un draft (pending_approval → drafting) | ❌ | ❌ | ✅ | ❌ | ✅ |
| Soumettre un draft (drafting → pending_approval) | ❌ | ❌ | ✅ | ❌ | ✅ |
| Approuver / rejeter un draft à l'itération courante | ❌ | ❌ | ❌ | ✅ | ✅ |
| Choisir destination = "dev humain" à la soumission | ❌ | ❌ | ✅ | ❌ | ✅ |
| Choisir destination = "AutoDev" à la soumission | ❌ | ❌ | ❌ | ❌ | ✅ |

Note : un owner-auteur doit valider son propre draft (cf. section A : validation obligatoire de tous les owners, y compris l'auteur). Donc le row "auteur = owner" inclut bien l'action "approuver".

### Destination du draft

Ajout d'une colonne `destination` sur `autospec_drafts` :

```ruby
t.string :destination, null: false  # 'human' | 'autodev'
```

Choisie au moment de la transition `drafting → pending_approval` (clic "Créer le ticket") :
- Contributor-auteur : un seul bouton de soumission, destination forcée à `human`.
- Owner-auteur : deux boutons disponibles ("Envoyer à un dev humain" / "Envoyer à AutoDev"), choix explicite.

Au moment de la création GitLab (post-approbation), `destination` détermine les labels appliqués (label autodev `labels_todo` si destination = `autodev`, label "à assigner" sinon). Pas de modification de destination post-soumission au MVP — si un owner veut rediriger après coup, c'est via la gestion classique des labels GitLab sur le ticket existant.

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| Un projet sans owner = aucun draft ne peut être approuvé | Validation au moins un owner par projet en création/édition projet (contrainte UI + check applicatif) |
| Owner-auteur unique = workflow d'approbation trivial (un seul clic sur soi-même) | Acceptable au MVP, c'est la conséquence de "validation de tous les owners y compris l'auteur" |
| Contributor crée draft pour un projet où il a un owner pas réactif | Pas de SLA, le draft reste en `pending_approval`. Visible dans "mes brouillons" côté auteur. À traiter par discussion offline pour le MVP. |
| Rétrogradation d'un owner en contributor avec drafts en `pending_approval` en cours | Approvals déjà donnés conservés (audit trail), mais l'ancien owner ne peut plus en approuver de nouveaux. À documenter, comportement par défaut acceptable. |
| Tentative de bypass via API (contributor force destination=autodev) | Validation côté contrôleur via les helpers `owner_of?`, jamais via paramètre client direct |

---

## K. Notifications

Décision MVP : **aucune notification, pull-only via dashboard**. Pas d'email, pas de Teams, pas de webhook. Les acteurs viennent chercher l'information sur leur dashboard.

### Pour les owners (zone 3)

Encart dashboard "Tickets à approuver" :
- Liste les drafts en `pending_approval` à l'itération courante où l'owner connecté n'a pas encore voté.
- Badge dans la navigation latérale avec le compteur.
- Aucun email envoyé, aucune notif Teams.

L'owner doit penser à consulter — au MVP c'est explicite, simple, sans dépendance infra.

### Pour les auteurs (zone 4)

Vue "Mes brouillons" :
- Liste tous les drafts de l'utilisateur connecté (tous statuts, filtrables).
- Affiche le statut courant et l'historique des approvals (qui a approuvé/rejeté, quand, raison du rejet le cas échéant).
- Encart "Action requise" pour les drafts en `rejected` qui appellent une réponse de l'auteur.

L'auteur revient consulter — même logique pull, même simplicité.

### Pourquoi pas de notifications au MVP

- **Pas d'infra mail/Teams existante** côté Autodev. Ajout = un service supplémentaire à maintenir (SMTP, webhook Teams, gestion erreurs/retries, opt-out, throttling).
- **Périmètre pilote restreint** : un seul CSM pilote en bêta, le besoin de notifs asynchrones est faible quand on est en boucle courte.
- **Risque de bruit** : sans réglages fins, le push notif sur chaque transition devient pénible et sera désactivé.
- **Coût d'ajout post-MVP est faible** : l'écran "Mes brouillons" et l'encart owner exposent déjà les events qu'on voudra envoyer. Brancher Mailer/Webhook plus tard = un job qui consomme les mêmes hooks.

### Pièges identifiés

| Piège | Mitigation |
|---|---|
| Owner ne consulte pas son dashboard pendant des jours | Acceptable au MVP. Si la friction se manifeste, ajouter un mail/Teams en V2 (les hooks existent déjà). |
| Auteur ne sait pas que son draft a été rejeté | Idem. La vue "Mes brouillons" est l'endroit naturel à consulter. |
| Tentation d'ajouter "juste un petit email" en cours de route | Tenir le no-notifs MVP : sinon on glisse vers de l'infra qui n'est pas le sujet du pilote. |
| Pas de signal de présence d'un nouveau draft pour les owners | Acceptable. Si vraiment bloquant, un compteur Turbo Stream en live sur le badge sidebar peut suffire sans email — c'est gratuit côté infra. |

---

## L. Streaming SSE : limitation observée et décision à revalider à l'implem AutoSpec

La décision de section A ("ActionCable est overkill pour du one-way LLM streaming") tenait avec les hypothèses du cadrage : un canal sortant peu fréquent, peu d'onglets concurrents, payload léger. À l'usage AutoDev, un coût opérationnel est apparu qui doit être documenté avant d'attaquer l'implem AutoSpec, où la pression sur ce canal augmentera.

### Symptôme observé

`StreamController#show` utilise `ActionController::Live` et boucle sur `Web::EventBus.subscribe.pop(timeout: HEARTBEAT_INTERVAL)`. Chaque onglet dashboard ouvert **parque un thread Puma** pour la durée de vie de la connexion. À chaque F5, le navigateur ferme l'EventSource côté client, mais `Queue#pop` ne voit pas la coupure TCP — le thread reste parqué jusqu'au prochain tick, où `write(": ping\n\n")` lève `ClientDisconnected` et le thread est libéré.

Avec un pool Puma à 10 (déjà remonté de 3 → 10 explicitement pour ça), enchaîner quelques refresh ou cumuler plusieurs onglets saturait le pool : toutes les requêtes Rails freezaient, restart serveur obligatoire. Le profil AutoDev actuel l'a fait apparaître sur des refresh successifs du dashboard côté Bobette.

### Mitigation court terme (en place)

Deux changements minimaux qui ne remettent pas en cause l'architecture :

1. **Fermeture proactive côté client sur `pagehide`** dans `Layout::APP_JS` : `window.addEventListener('pagehide', () => window.__autodevSSE?.close())`. Le navigateur envoie un FIN TCP immédiat, le thread serveur prend la `ClientDisconnected` au write suivant sans attendre le heartbeat. Couvre le cas courant (F5, fermeture d'onglet, navigation cross-document).
2. **`HEARTBEAT_INTERVAL` baissé de 15 → 5 secondes** dans `StreamController`. Filet de sécurité pour les morts silencieuses où aucun event JS ne fire (kill navigateur, perte réseau, sleep machine, bfcache imparfait). Trade-off CPU/réseau négligeable (3 pings vides/min/onglet).

La limitation architecturale reste : un thread Puma par onglet vivant, et la dépendance au heartbeat pour les morts silencieuses.

### Pourquoi se reposer la question à l'implem AutoSpec

Le profil de charge AutoSpec change la donne par rapport à l'usage AutoDev actuel :

- **Streaming LLM token-by-token** : fréquence d'écriture nettement plus élevée que les `activity_events` sporadiques d'aujourd'hui. Un thread parqué + actif sur N onglets pèse plus.
- **Multi-CSM concurrent** attendu en bêta puis en prod, ≥ 1 onglet par CSM. Le pool Puma à 10 sature vite si chaque onglet squatte un thread.
- **`Web::EventBus` est strictement in-process** : les events créés par le worker Solid Queue (process séparé du process web) n'atteignent pas les abonnés SSE. Aujourd'hui ça passe parce que les events critiques pour le dashboard sont émis depuis le process web (transitions AASM côté contrôleurs). AutoSpec ajoute des broadcasts depuis le pipeline LLM — c'est le moment où ce trou d'IPC se manifestera.
- **ActionCable + Solid Cable** (le défaut Rails 8 remplaçant Redis comme backend pub/sub d'ActionCable) règle les deux problèmes d'un coup : le hijack WebSocket libère le thread Puma après le handshake (la connexion vit dans l'event loop d'ActionCable), et Solid Cable porte le pub/sub vers une 3ᵉ DB SQLite partagée entre process — les broadcasts depuis le worker atteignent les abonnés du process web.

### Critères de décision au moment de l'implem

- Si le streaming LLM mesuré reste tolérable avec les mitigations + pool Puma remonté, et si les broadcasts critiques restent émis depuis le process web → rester sur SSE + `Web::EventBus`.
- Si on observe saturation du pool, perte d'events inter-process, ou si AutoSpec veut broadcaster depuis le worker → migrer vers ActionCable + Solid Cable. Coût estimé : ~50 lignes nettes (Channel + `cable.yml` + JS client + remplacement de `Web::EventBus.publish` par `ActionCable.server.broadcast`, ajout d'une 3ᵉ DB SQLite). Le bonus IPC inter-process tombe gratuitement.
- `Web::EventBus` peut soit rester en façade par-dessus ActionCable (refactor minimal), soit disparaître au profit de broadcasts directs.

À acter au moment où le streaming AutoSpec passe en intégration, pas avant — la mesure réelle prime sur l'estimation.

---

## Références

- Compte-rendu de réunion : `point_produit-autodev.md` (racine du repo `tooling`).
- Design handoff v2 (édition centrale) : `autodev/docs/design/spec_update/`.
- Design handoff v1 (chat plein écran, conservé pour historique) : `autodev/docs/design/`.
- Architecture Autodev actuelle : `autodev/CLAUDE.md`.
