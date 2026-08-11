# Observabilité & santé d'Autodev

Référence technique de la surface de monitoring d'Autodev : endpoints de santé sondables de l'extérieur, heartbeat du poller, et page admin `/admin/health`.

> **Principe** : Autodev n'émet **aucune alerte sortante** (pas de mail, Slack, ni ticket GitLab). Il **expose** son état ; l'alerte se configure côté sonde externe (Datadog, BetterStack…) sur les endpoints ci-dessous.

## Pourquoi

Le système est piloté par des jobs en arrière-plan (poller récurrent → dispatch → jobs par issue). Un échec peut être **silencieux** : un poller qui ne tourne plus, un worker mort, un quota Claude épuisé, ou un bug qui ne fait pas échouer de ticket (cf. le bug du sparkline « Activité de la semaine », qui renvoyait des barres à zéro sans que rien ne le signale). Cette surface répond à « est-ce qu'Autodev tourne ? » de façon vérifiable, par un humain (`/admin/health`) comme par une machine (`/healthz`).

## Composants surveillés — `Autodev::HealthReport`

`app/services/autodev/health_report.rb` est la **source de vérité unique**, partagée par les endpoints JSON et la page admin. Elle est **passive** : elle ne lit que de l'état déjà enregistré, ne shell-out jamais vers `danger-claude` et n'appelle pas GitLab — donc instantanée et sans risque, même martelée par une sonde.

`#call` renvoie :

```json
{
  "status": "ok",                       // pire sévérité parmi les checks
  "generated_at": "2026-06-17T09:00:00Z",
  "checks": {
    "poller":       { "status": "ok",   "detail": "...", "meta": { "last_poll_at": "...", "age_seconds": 42 } },
    "workers":      { "status": "ok",   "detail": "...", "meta": { "workers": 3 } },
    "queue":        { "status": "ok",   "detail": "...", "meta": { "failed": 0, "pending": 1 } },
    "claude_usage": { "status": "ok",   "detail": "...", "meta": { "checked_at": "..." } },
    "issues_error": { "status": "warn", "detail": "...", "meta": { "count": 2 } },
    "stuck_issues": { "status": "warn", "detail": "...", "meta": { "count": 1, "sample": "#15830(pending)" } },
    "database":     { "status": "ok",   "detail": "..." }
  }
}
```

Sémantique de `status` (`ok` < `warn` < `down`, le global = le pire) :

| Check | `ok` | `warn` | `down` |
|---|---|---|---|
| **poller** | heartbeat récent | — | aucun heartbeat (en prod) ou trop vieux |
| **workers** | ≥ 1 worker vivant | — | aucun process / aucun worker vivant |
| **queue** | pas d'échec, file basse | jobs en échec, ou backlog > 100 | — |
| **claude_usage** | dernier poll : quota dispo | dernier poll : quota épuisé | — |
| **issues_error** | aucune issue en erreur | ≥ 1 issue `error` / `post_completion_error` | — |
| **stuck_issues** | aucune issue bloquée | ≥ 1 issue dans un état actif sans avancement | — |
| **database** | primaire + queue joignables | — | exception SQL |

- **poller** se base sur le dernier `ActivityEvent` `kind: 'poller'`. Seuil de péremption = `poll_interval × monitoring.poll_stale_factor`, avec un plancher de 15 min. En environnement local (dev/test, où `config/recurring.yml` désactive les jobs récurrents), l'absence de heartbeat n'est **pas** une faute → `ok` (`poller disabled`).
- **issues_error** est un `warn`, jamais un `down` : des tickets en erreur sont un état opérationnel normal, pas une panne système.
- **stuck_issues** matérialise l'invariant qu'un dashboard tout vert masquait : toute issue dans un état non-terminal et non-attente-humaine a une passe du dispatcher qui la fait avancer, donc elle doit produire de l'activité. Lève un `warn` (jamais `down`) si une issue `pending` dépasse la fenêtre de péremption du poller (`max(poll_interval × poll_stale_factor, 900s)` — elle devrait quitter `pending` en un cycle) ou si une issue active (`cloning`…`creating_mr`, `reviewing`, `fixing_*`, `running_post_completion`, `answering_question`) n'a plus d'`ActivityEvent` depuis la fenêtre d'inactivité — `max(monitoring.stuck_active_after_seconds ou 2 h, 2 × le plus long timeout configuré)`, pris sur `dc_timeout`, `mr_review_timeout` **et** `post_completion_timeout` de tous les projets connus (Autodev #50). Cette fenêtre est aussi la borne de sûreté de `dispatch_dormant_audit`, qui mute les lignes hors du verrou de concurrence par ticket : elle doit dépasser le plus long silence qu'un worker *vivant* peut produire. C'est pourquoi un réglage explicite plus étroit est ignoré (la valeur effective est renvoyée dans `meta.window_seconds`) et pourquoi chaque appel danger-claude écrit un `ActivityEvent` `kind: 'heartbeat'` (DB uniquement, invisible dans l'UI) : sans lui, une boucle comme `PipelineFixer` — deux appels par job échoué, aucun événement entre les jobs — dépasse la fenêtre alors que le worker travaille toujours ; avec lui, le calcul reste basé sur la dernière activité (heartbeat compris), donc un run danger-claude long mais vivant n'est pas flaggé. **Exclus volontairement** : `done`/`closed` (terminaux), `error` (panneau dédié + backoff), `needs_clarification` (attente humaine), `checking_pipeline` (attente d'un pipeline externe, re-pollé chaque cycle). Cas typique détecté : une issue remise à `pending` au redémarrage dont le label GitLab est resté `label_doing`, donc invisible à `dispatch_new_issues`.
- **Corollaire de la #53 — pourquoi l'exclusion de `checking_pipeline` reste correcte.** Une ligne surveillée n'écrivait plus un `ActivityEvent` par poll : depuis la #53, l'entrée d'activité répétée est *remplacée sur place* (même ligne, `created_at` avancé) au lieu d'être ajoutée — 477 827 des 898 424 lignes de production étaient des polls, dont 29 773 sur le seul ticket #15894. Le point important pour l'invariant ci-dessus : la fraîcheur ne change pas. Une ligne pollée au dernier cycle porte toujours un événement daté du dernier cycle, donc `Issue.without_activity_since` voit exactement ce qu'elle voyait avant — ce n'est pas « aucun lecteur n'est concerné », c'est « les entrées de la requête sont inchangées ». Indépendamment de cela, `checking_pipeline` n'est ni dans `Issue::STALLED_STATES` ni dans l'une des deux moitiés de cette carte, donc ni `dispatch_dormant_audit` ni la carte ne regardent une ligne surveillée, aussi silencieuse soit-elle. Les deux faits sont épinglés par `test/pipeline_watch_invariant_test.rb`, y compris un garde qui casse si quelqu'un ajoute `checking_pipeline` à l'une de ces trois constantes.
- **Ce que la #53 change vraiment côté UI** : le sparkline « Activité de la semaine » ne compte plus une barre par poll (il mesurait la surveillance, pas le travail), `/stream` ne reçoit plus une frame par poll (`update_columns` ne déclenche pas `after_create_commit`), et la timeline de `/issues/:id` n'est plus saturée de lignes de poll. Une surveillance est par ailleurs désormais **bornée dans le temps** : au-delà de `pipeline_watch_max_days` (défaut 14 j) sans transition, la demande passe `done` + `needs_attention` (`pipeline_watch_expired`) — voir `docs/usage/autodev-technical-usage.md`.
- **Corollaire à noter** : la carte mesurait auparavant l'absence d'activité *métier* ; elle mesure maintenant l'absence d'appel danger-claude *démarré* depuis la fenêtre. Un run long mais vivant n'est donc plus signalé à tort — c'est le but — mais un worker qui tournerait sans avancer (boucle danger-claude qui s'auto-relance sans jamais atteindre une transition) échapperait désormais à ce check. Aucune boucle de ce type n'existe dans le code à ce jour ; c'est une perte de sensibilité assumée du seul check censé détecter « plus de chemin possible ».
- Toute exception dans un check est rattrapée et dégradée en `down` (la page / l'endpoint ne plante jamais).

## Heartbeat du poller — `kind: 'poller'` / `kind: 'error'`

`AutodevPollJob#perform` (`app/jobs/autodev_poll_job.rb`) émet un `ActivityEvent` **système** (`issue_id` nul) :

- **fin de cycle réussie** → `kind: 'poller'`, `level: 'info'`, payload `{ event: 'cycle_complete', usage_ok: true, projects: N, duration_ms: … }` ;
- **cycle sauté (quota épuisé)** → `kind: 'poller'`, `level: 'warn'`, payload `usage_ok: false` ;
- **exception au niveau cycle** → `kind: 'error'`, `level: 'error'`, payload `{ event: 'cycle_failed', error:, backtrace: … }`, **puis l'exception est relancée** (Solid Queue enregistre l'échec dans `solid_queue_failed_executions`).

> Ces deux `kind` étaient déclarés dans `ActivityEvent::KINDS` depuis l'origine mais n'étaient jamais émis — la brique de heartbeat était prévue puis jamais branchée.

**Règle des events système** : un `ActivityEvent` sans `issue_id` (heartbeat / marqueur d'erreur cycle) :

- **n'est pas diffusé** sur le flux SSE `/stream` (`ActivityEvent#broadcast_to_event_bus` court-circuite) — sinon un heartbeat toutes les 5 min spammerait le live feed ;
- **n'est pas compté** dans le sparkline « Activité de la semaine » (`Web::Helpers#weekly_activity_counts` exclut `kind IN ('poller','error')`) — sinon ~288 heartbeats/jour noieraient l'activité réelle.

La colonne `activity_events.issue_id` est nullable depuis la migration `20260617000002` (le modèle déclarait déjà `belongs_to :issue, optional: true`).

## Endpoints de monitoring (non authentifiés)

`MonitoringController` saute le gate SSO global (`skip_before_action :authenticate_user!`, comme `AssetsController`) : une sonde externe ne peut pas faire le handshake Microsoft 365. Le payload est volontairement non sensible (aucun secret, aucun chemin disque).

| Endpoint | Rôle | Code HTTP |
|---|---|---|
| `GET /up` | Liveness pure (le process Rails répond) — `Rails::HealthController` | 200 |
| `GET /healthz(.json)` | `HealthReport` complet en JSON | **503 seulement si `down`** ; `ok` **et** `warn` → 200 |
| `GET /healthz/:check` | Un seul composant (`poller`, `workers`, `queue`, `claude_usage`, `issues_error`, `database`) | idem (503 si `down`) |

Les sondes alertent sur le **code HTTP** ; le corps JSON sert au diagnostic.

**503 = vraie panne uniquement** (`down` : poller périmé, 0 worker, base injoignable). Un `warn` (jobs en échec, issues en erreur) est un état *dégradé mais debout* et renvoie **200** — sinon une sonde uptime sonnerait en permanence sur des conditions opérationnelles normales (p. ex. des tickets en erreur). Pour alerter aussi sur `warn`, brancher une sonde secondaire (basse sévérité) sur le corps JSON — voir « Sondes » plus bas.

### Token optionnel

Si `monitoring.token` est défini dans `~/.autodev/config.yml`, les endpoints `/healthz*` exigent le token (`Authorization: Bearer <token>` ou `?token=<token>`), sinon `401`. Par défaut (`nil`), ils sont ouverts — cohérent avec le modèle de confiance 127.0.0.1 / NetBird du reste du dashboard. Comparaison via `ActiveSupport::SecurityUtils.secure_compare`.

### Exemples

```bash
# Liveness
curl -i https://autodev.interne/up

# Santé complète
curl -s https://autodev.interne/healthz.json | jq

# Avec token
curl -s -H "Authorization: Bearer $AUTODEV_HEALTH_TOKEN" https://autodev.interne/healthz.json | jq

# Un seul composant (pour une sonde dédiée)
curl -i https://autodev.interne/healthz/poller
```

**BetterStack** :

- *Monitor critique (paging)* : HTTP monitor sur `/healthz`, type « expect status code 200 ». Ne sonne que sur une **vraie panne** (`down`), pas sur un `warn`. Ajouter le header `Authorization: Bearer <token>` si `monitoring.token` est posé. `check_frequency` 180 s, `confirmation_period` 120 s (anti-flapping).
- *Monitor basse sévérité (optionnel, email)* : HTTP monitor sur `/healthz` avec `required_keyword` = `"status":"ok"` → alerte dès que le corps n'est plus `ok` (donc aussi sur `warn` : jobs en échec, issues en erreur).

**Datadog** : *Synthetic HTTP test* sur `/healthz`. Assertion `status is 200` pour le paging (down only) ; pour un check plus strict, ajouter une assertion JSONPath `$.status is "ok"` (warn + down) sur un test à seuil d'alerte plus bas.

## Page admin `/admin/health`

`Admin::HealthController` (admin only) rend `Web::Views::Admin::Health` à partir du **même** `HealthReport`. Une carte par composant avec sa pastille de statut, plus des liens vers l'inspecteur de jobs (`/admin/jobs`, Mission Control) et vers `/healthz.json`. Strictement passive.

## Configuration

Bloc `monitoring` dans `~/.autodev/config.yml` (défauts dans `lib/autodev/config.rb`) :

```yaml
monitoring:
  token: null            # nil = endpoints ouverts ; sinon Bearer/?token= requis
  poll_stale_factor: 3   # poller "down" après poll_stale_factor × poll_interval (plancher 15 min)
```

Réglage global associé, hors bloc `monitoring` (défaut dans `lib/autodev/config.rb`) :

```yaml
pipeline_watch_max_days: 14   # abandon d'une surveillance de pipeline sans transition ; 0 = désactivé
```

`poll_interval` (défaut 300 s) est la cadence du poller (`config/recurring.yml`, dérivée de `AUTODEV_POLL_INTERVAL`).

## TODO / pistes futures

Volontairement hors du périmètre de la première itération :

- **Sonde active à la demande** — un bouton « tester maintenant » sur `/admin/health` qui lance réellement une vérification de connectivité GitLab et un `UsageChecker` (shell-out `danger-claude`). Aujourd'hui la page est strictement passive pour rester instantanée ; ce serait une action explicite, séparée du chargement.
- **Métriques de tendance** — taux d'échec des jobs dans le temps (graphe), profondeur de file historisée, durée des cycles de poll. Nécessite d'agréger l'historique Solid Queue / les heartbeats plutôt que de lire l'instantané.
- **Forecast de quota Claude** — estimer « quota épuisé dans ~X » à partir de la consommation observée, plutôt que de ne refléter que le dernier état connu.

> Rappel : l'**alerting sortant** (mail / Slack / ticket GitLab) reste hors périmètre par décision produit — l'alerte se fait côté sonde externe branchée sur `/healthz`.
