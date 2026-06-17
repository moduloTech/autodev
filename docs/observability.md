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
| **database** | primaire + queue joignables | — | exception SQL |

- **poller** se base sur le dernier `ActivityEvent` `kind: 'poller'`. Seuil de péremption = `poll_interval × monitoring.poll_stale_factor`, avec un plancher de 15 min. En environnement local (dev/test, où `config/recurring.yml` désactive les jobs récurrents), l'absence de heartbeat n'est **pas** une faute → `ok` (`poller disabled`).
- **issues_error** est un `warn`, jamais un `down` : des tickets en erreur sont un état opérationnel normal, pas une panne système.
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
| `GET /healthz(.json)` | `HealthReport` complet en JSON | **200 si `ok`, sinon 503** |
| `GET /healthz/:check` | Un seul composant (`poller`, `workers`, `queue`, `claude_usage`, `issues_error`, `database`) | 200 / 503 |

Les sondes alertent sur le **code HTTP** ; le corps JSON sert au diagnostic.

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

**BetterStack** : créer un *Heartbeat/HTTP monitor* sur `/healthz` (ou `/healthz/poller`), alerte si le code ≠ 200. Pour un endpoint protégé, ajouter le header `Authorization`.

**Datadog** : *Synthetic HTTP test* sur `/healthz`, assertion `status is 200`. Optionnellement, parser le JSON et alerter sur `checks.poller.status`.

## Page admin `/admin/health`

`Admin::HealthController` (admin only) rend `Web::Views::Admin::Health` à partir du **même** `HealthReport`. Une carte par composant avec sa pastille de statut, plus des liens vers l'inspecteur de jobs (`/admin/jobs`, Mission Control) et vers `/healthz.json`. Strictement passive.

## Configuration

Bloc `monitoring` dans `~/.autodev/config.yml` (défauts dans `lib/autodev/config.rb`) :

```yaml
monitoring:
  token: null            # nil = endpoints ouverts ; sinon Bearer/?token= requis
  poll_stale_factor: 3   # poller "down" après poll_stale_factor × poll_interval (plancher 15 min)
```

`poll_interval` (défaut 300 s) est la cadence du poller (`config/recurring.yml`, dérivée de `AUTODEV_POLL_INTERVAL`).

## TODO / pistes futures

Volontairement hors du périmètre de la première itération :

- **Sonde active à la demande** — un bouton « tester maintenant » sur `/admin/health` qui lance réellement une vérification de connectivité GitLab et un `UsageChecker` (shell-out `danger-claude`). Aujourd'hui la page est strictement passive pour rester instantanée ; ce serait une action explicite, séparée du chargement.
- **Métriques de tendance** — taux d'échec des jobs dans le temps (graphe), profondeur de file historisée, durée des cycles de poll. Nécessite d'agréger l'historique Solid Queue / les heartbeats plutôt que de lire l'instantané.
- **Forecast de quota Claude** — estimer « quota épuisé dans ~X » à partir de la consommation observée, plutôt que de ne refléter que le dernier état connu.

> Rappel : l'**alerting sortant** (mail / Slack / ticket GitLab) reste hors périmètre par décision produit — l'alerte se fait côté sonde externe branchée sur `/healthz`.
