# The spec check blocks an undescribed decision — design (Autodev #122)

## The defect

POWERPANNE#14746 (A#111, MR !11409). On 29/06/2026 autodev asked whether the
request meant (a) an automatic monthly e-mail or (b) a screen to choose a
period; the requester answered (b). On 28/08/2026 the row came back through
`clarification_received`, and the spec check cleared it in 23 seconds
(`checking_spec` 11:02:10 → `implementing` 11:02:33 UTC, production
`activity_events`). The ticket still left three holes on (b):

1. where the screen lives and who may use it — raised on 18/02 by a
   participant (a screen reserved to one company, feature flipping), never
   answered;
2. the output — download, or e-mail to the address given for the monthly send;
3. whether (b) replaces (a) or comes on top of it — the description still read
   "Demande d'envoi mensuel".

The implementation followed the description rather than the answer. #121
handles what happens after; this ticket is the check that let it through.

## Decisions

### 1. The prompt carries explicit blocking criteria

`IssueProcessor::Prompts::SPEC_CHECK` had one rule about blocking, and it
pushed the other way ("des détails mineurs ne doivent pas bloquer
l'implémentation"). It now lists three cases, each sufficient for `unclear`
(owner's wording):

1. the description contradicts an answer given later in the comments;
2. a decision is taken but what it implies is not described — screen or place,
   access, output (download, e-mail and recipient, display), replace or add;
3. an answer to a previous clarification changes the nature of the request:
   `implementation` only once (2) is satisfied for the new request.

Each listed problem is to be written as a question the requester can settle,
quoting what contradicts or what is missing. Pragmatism is kept, now scoped:
labels, column order, formatting, obvious defaults and internal technical
choices do not block, and neither does anything the code can settle. The
answer shape is unchanged.

### 2. The spec check runs on Claude Code's default model

The ticket asked for "a model stronger than haiku". Measured, that was not the
gap: production's global config sets `model: "claude-opus-4-7"` and
`effort: "xhigh"` (`~/.autodev/config.yml` on bobette, unchanged since
23/06/2026), and `DangerClaudeRunner#dc_global_args` resolves
project > global > per-call default, so the `'haiku'` the check passed was
never used there — the 28/08 check ran on Opus 4.7. Owner's decision (Q6): the
check stops passing `model: 'haiku'` and runs on Claude Code's default model.
In production that only takes effect once the deprecated settings below are
removed.

### 3. `model` and `effort` are deprecated now, removed later

Owner's decision: "Opus 4.7 is an old version and effort has changed". Until
removal they are read exactly as before, and setting either is signalled:

- at boot, `bin/autodev` (`warn_deprecated_model_settings`, inside
  `warn_settings`) prints a header with the count and one line per setting —
  `config.yml` for a global one, the project path for a per-project one — in
  the CLI locale. Production today: two lines, both global.
- on the project form (edit and new), a warning-coloured notice under the
  `model` and `effort` fields, and under no other field.
- in `docs/usage/autodev-technical-usage.md`.

`Config::DEPRECATED_MODEL_SETTINGS` is the one list; `Config.deprecated_model_settings`
reports globals first, then projects in the order given, and skips a blank
value. `IGNORED_GLOBAL_FIELDS` — the codebase's other deprecation list — is
deliberately not used: it drops the value, and production's setting would
silently switch off.

**What removal will change for the two other `'haiku'` callers.** The
complexity evaluation (`Implementer#evaluate_complexity`) and the pipeline
evaluation (`PipelineMonitor::Evaluator#evaluate_code_related`) keep passing
`model: 'haiku'`, by design: cheap JSON tasks. Today the global `model`
overrides that per-call default too, so they also run on Opus 4.7 in
production; removing the setting is what gives them haiku back. Every other
call — the spec check included — then runs on Claude Code's default model and
effort. Both halves are pinned (`TheCheapEvaluationsKeepHaikuTest`).

### 4. A blank `model` / `effort` is unset

Found by the plan review: `dc_global_args` read the settings with a bare `||`,
so a `model: ""` left in `config.yml` reached danger-claude as `-m ''` and hid
the per-call haiku default, while the boot warning (which skips blanks) said
nothing. `DangerClaudeRunner#model_setting` reads a blank value as unset. DB
rows were already safe (`Project#add_present`).

### 5. The verdict is read by walking the JSON, not by a regex

Nothing drove `check_specification` / `parse_spec_result` before; they are now
pinned end to end (`SpecCheckVerdictTest`). The plan review also showed the
brace-free regex `\{[^{}]*"type"…[^{}]*\}` failing on a question that quotes a
template (`{date}`) — and an unreadable answer *proceeds* to implementation, so
the request would be implemented without the questions just produced. The new
prompt asks the model to quote, which makes that likelier.
`IssueProcessor::JsonObjects.scan` returns every balanced `{…}` that parses as
a JSON object (braces inside JSON strings are not counted); the verdict is the
**last** object with a known `type` — the answer the model ended on, after any
example or restated schema. The legacy `{"clear": …}` shape goes through the
same scan. The fallback direction is unchanged: nothing readable → proceed.

## Proof: corpus evaluation, old prompt vs new prompt

### Corpus

POWERPANNE#14746 in its 28/08 state, and eight PowerPanne tickets autodev
delivered without being given up (`status = 'done'`, `needs_attention = 0`,
merge request not closed — production DB, 08/10/2026). Five went straight
through the check; two (14635, 14985) came back from a clarification, which is
exactly the population criterion 3 could over-block.

| Ticket | Title | Check ran at (UTC) |
|---|---|---|
| 14746 | [Export data Excel] "FACTURES MENSUELLES" | 2026-08-28 11:02:10 |
| 14635 | [Calculateur de ristournes] nb de dossiers "apporteur d'affaires" sur AXA | 2026-08-28 13:54:38 |
| 14985 | [Bruce] nombre de dossiers traités par la MULE | 2026-08-28 13:54:39 |
| 16364 | [Parc Fourrière] modale sur les colonnes "Commentaires Dossier" | 2026-07-17 14:48:10 |
| 16151 | [Consulter les accès] historique d'envoi de factures | 2026-08-06 13:52:25 |
| 16424 | [Historique Dépanneur] renommer la colonne "heure d'appel" | 2026-08-05 09:04:09 |
| 16341 | [Comptabilité] format FEC | 2026-08-06 11:10:13 |
| 16522 | [Recherche avancée] couleur des libellés | 2026-09-21 15:28:08 |
| 16580 | [Annulations] visibilité depuis le dispatch | 2026-09-21 15:56:08 |

### Method

- **Context as the check saw it.** `GitlabHelpers.fetch_issue_context` (the
  production code path) with two substitutions: issue notes cut at the moment
  the row entered `checking_spec` (the `clone_complete` transition), and the
  description replaced by the last GitLab description version recorded at or
  before that moment (GraphQL `systemNoteMetadata.descriptionVersion`). Five of
  the nine descriptions had been edited since the check (14746, 16364, 16424,
  16341, 16522), each time adding the Skynet link block of September; every
  ticket had a version at or before its cutoff, except 16151, never edited. Images were not downloaded.
- **Working directory**: a depth-1 clone of PowerPanne `master` at f25bea8
  (2026-10-02), the same for every call — not the tree each check saw.
- **Runner**: danger-claude's local OAuth session had expired, so the host
  `claude` CLI (2.1.295) ran the same prompt: `claude -p <prompt>
  --output-format json --add-dir /tmp --allowedTools Read,Grep,Glob
  --setting-sources project,local --strict-mcp-config`, plus `--model
  claude-opus-4-7 --effort xhigh` for the production arguments. Read-only tools,
  no user settings or MCP servers; the clone's own `CLAUDE.md` loaded, as in
  the container.
- **Verdict**: read with the pre-#122 regex, which parsed all 31 answers.
- 31 calls, US$ 12.08, 7–127 s each. The owner accepted about 18; the 10
  repeated draws below were added because a single draw could not explain the
  first result.

### Results

| Ticket | Old prompt, Opus 4.7 xhigh | New prompt, Opus 4.7 xhigh | New prompt, default model (Opus 5.5) |
|---|---|---|---|
| 14746 | **unclear 5/5** (5–7 points) | **unclear 5/5** (3–4 points) | unclear (5 points) |
| 14635 | implementation | implementation | — |
| 14985 | implementation | implementation | implementation |
| 16364 | implementation | implementation | — |
| 16151 | implementation | implementation | — |
| 16424 | implementation | implementation | — |
| 16341 | implementation | unclear 1/3, implementation 2/3 | implementation |
| 16522 | unclear (2 points) | implementation | — |
| 16580 | unclear (3 points) | implementation | — |

Counts on the eight delivered tickets, first draw: old prompt **6/8**
implementation, new prompt **7/8**. Over every draw on them, the new prompt
answered `unclear` 1 time in 10, the old one 2 in 8.

**14746, the three holes.** Every new-prompt answer (6/6, both models) asks
where the screen lives and who may access it, and asks the output question
(download or e-mail). Replace-vs-add is asked explicitly in 5 of the 6 —
draw #2 folds it into "e-mail, download, or both?". The old prompt lists the
same holes but drowns them in five to seven points, several of them minor
(column formats, multi-valued fields, an unreachable attachment) — exactly what
criterion 2 and the scoped pragmatism separate.

### What this does and does not prove

- **It does not reproduce the production failure.** The old prompt on the
  production model blocked 14746 in 5 draws out of 5 here, where production
  cleared it on 28/08. Not the model (config unchanged since June), not the
  prompt (text unchanged since April). What differs and was not reproduced: the
  danger-claude container, the tree at the time, the downloaded images (one in
  the decisive answer), and sampling at production's single draw. So the
  evaluation shows the new prompt blocks 14746 for the right reasons; it cannot
  show the old one would have cleared it again.
- **Over-questioning was measured, not supposed**: none observed beyond the old
  prompt's own rate on this corpus. 16341's one `unclear` (1 of 3 draws) asks a
  real question — "imprts de règlements" is a typo for imports or exports, and
  the two are different features.
- Eight tickets is a small corpus; a rate of 1/10 is an estimate with a wide
  interval.

## Assumptions

- "Delivered successfully" = `done`, not flagged, merge request not closed (1
  of the 8 is merged; the rest await feature review).
- The description at a cutoff is the last description version at or before it.
- One `master` tree stands for the trees the checks saw.
- The host `claude` CLI stands for danger-claude's container.
- The docs are French (`docs/usage/`), so the notice there is French only; the
  two user-facing strings (boot warning, form notice) are fr + en.

## Out of scope, for the owner

- `IssueFormatter.append_comments` drops every note containing `**autodev**`,
  autodev's own questions included. In 14746 the check therefore read
  "3. (b) Une interface…" without the question that defines (a) and (b), and
  only inferred what (b) replaced. Restoring them changes the context of every
  prompt, not only this one.

## Appendix — every `unclear` answer

The client's e-mail address is masked.

#### #14746 — old prompt, prod: `unclear`

- Mode de déclenchement ambigu : les commentaires parlent à la fois d'un envoi mensuel automatique par email (destination <client address>) et d'une interface utilisateur permettant à l'utilisateur de choisir une période (point 3 de Bryan ALVES) — faut-il implémenter les deux, ou seulement l'export à la demande via UI ?
- Portée fonctionnelle non définie : la fonctionnalité doit-elle être réservée à la société RAD (feature flipping / interface cachée, ce qu'Emily déconseille explicitement) ou disponible pour toutes les sociétés ?
- Emplacement de l'interface utilisateur dans l'application non spécifié (dans la page société, dans la gestion commerciale, dans un menu dédié ?)
- Définition d'une mission AVA non précisée : la règle « N° mission si AVA / sinon adresse postale » dépend d'un critère métier à expliciter (seul un exemple d'URL est fourni, sans règle de détermination)
- Mécanisme de livraison du fichier généré non défini : téléchargement direct, envoi par email à l'adresse configurée, ou les deux ?
- Pour les champs multi-valués (Dépanneur, Type de paiement, Date de règlement), le format « séparés par une virgule » est indiqué mais l'ordre et la source exacte (ex : tous les paiements de la facture ? uniquement les validés ?) ne sont pas précisés

#### #14746 — old prompt, prod#2: `unclear`

- Mode de livraison ambigu : UI permettant un téléchargement direct, ou génération déclenchée via UI puis envoi automatique par email à <client address> (ou les deux) ?
- Emplacement de l'UI non spécifié dans l'application (quel menu, quelle page : gestion commerciale, section exports, page dédiée côté société RAD ?)
- Périmètre d'accès : la feature est-elle restreinte à la société 471 - RAD uniquement, ou doit-elle être générique/activable pour d'autres clients, et quelle(s) permission(s) FeatureTree utiliser ?
- Référence de date non arbitrée : date de création de la facture vs date de facturation (question explicitement posée par Emily, Bryan répond 'date de création' mais sans confirmation définitive — à verrouiller)
- Champ 'N° mission si AVA / si non → adresse postale' : critère exact pour déterminer si une mission est 'AVA' non défini (type de mission, champ booléen, origine d'appel ?)
- Format de certains champs multivalués (Dépanneur, Type de paiement, Date de règlement) : ordre d'énumération des valeurs séparées par virgule non précisé
- Champ 'Devenir véhicule' : source de la donnée dans le modèle non indiquée

#### #14746 — old prompt, prod#3: `unclear`

- Mécanisme de livraison ambigu : le ticket mentionne un envoi mensuel par email à <client address>, mais le commentaire clé (point 3 de Bryan ALVES) demande une interface utilisateur permettant de choisir une période jusqu'à 1 mois — on ne sait pas si l'export doit être téléchargé via l'UI, envoyé par email automatiquement chaque mois, ou les deux.
- Portée/visibilité de la fonctionnalité non précisée : feature réservée à la société RAD (471) ou générique pour toutes les sociétés ? Si réservée à RAD, où placer l'UI (admin, feature flipping, écran dédié) ? Emily Betham a explicitement soulevé ce point sans réponse claire.
- Mapping de plusieurs champs vers le modèle de données non spécifié : 'Devenir véhicule', 'Panne(Diagnostic)/Accident', 'Date de règlement (divers)', 'Jour de l'intervention' — aucune indication de la source exacte dans PP (contrairement à 'Origine d'appel' qui est explicitement = Donneur d'ordre).
- Signification et gestion de 'N° mission si AVA / si non → adresse postale' partiellement explicitée : un exemple de mission AVA est donné mais le critère technique distinguant AVA/non-AVA n'est pas défini.
- Format de sortie précis non spécifié : nom du fichier, en-têtes exactes, ordre des colonnes, format des dates — un .xlsx d'exemple est référencé mais son contenu n'est pas inclus dans le ticket.

#### #14746 — old prompt, prod#4: `unclear`

- Le mode de livraison n'est pas tranché : la description initiale parle d'un envoi mensuel automatique à <client address>, mais le dernier commentaire de Bryan (2026-06-29) demande une interface utilisateur permettant de choisir une période jusqu'à 1 mois — on ne sait pas s'il faut l'un, l'autre, ou les deux.
- L'emplacement de l'interface d'export dans l'application n'est pas précisé (nouvelle page dédiée ? intégration dans la gestion commerciale existante ? sous /companies/r-a-d/... ?).
- La portée fonctionnelle n'est pas claire : feature spécifique à la société RAD (471) uniquement, ou export générique activable pour d'autres sociétés (feature flag / permission) ? Les commentaires d'Emily évoquent explicitement la gêne à cacher une interface à tout le monde sauf eux.
- Le format exact du fichier Excel attendu est dans la pièce jointe FACTURES_MENSUELLES.xlsx qui n'est pas accessible — ordre des colonnes, en-têtes, mises en forme, feuilles, totaux éventuels inconnus.
- Les permissions / profils autorisés à déclencher cet export ne sont pas spécifiés (via FeatureTree ?).
- Granularité d'une ligne : une ligne par facture ? par mission ? par ligne de facture ? Non précisé explicitement, surtout quand plusieurs dépanneurs/paiements/règlements sont concaténés par virgule.

#### #14746 — old prompt, prod#5: `unclear`

- La demande oscille entre deux solutions sans trancher: envoi automatique mensuel par email vs interface utilisateur permettant de choisir une période (jusqu'à 1 mois). Le dernier commentaire mentionne l'UI mais l'email de destination <client address> suggère toujours un envoi automatique — les deux sont-ils demandés ou un seul?
- Portée de la fonctionnalité non précisée: solution spécifique à la société RAD (id 471) uniquement, ou feature générique configurable pour n'importe quelle société? La discussion initiale soulevait justement le problème du 'caché à tout le monde sauf eux'.
- Emplacement et contrôle d'accès de l'UI non spécifiés: où dans l'application cette interface doit-elle être placée et qui doit y avoir accès (profil, feature flag, feature tree)?
- Ambiguïté sur la date de référence (non résolue dans les commentaires): date de création de facture vs date de facturation (question posée par Emily à cause de l'antidatage, Bryan répond 'Date de création' mais sans validation claire côté métier).
- Mapping précis de certains champs non documenté: 'Devenir véhicule', 'Panne(Diagnostic)/Accident', 'Jour de l'intervention' — leur source dans le modèle de données n'est pas identifiée.
- Comportement attendu quand aucune donnée AVA n'existe mais que l'adresse postale est également absente, ou quand plusieurs dépanneurs/paiements existent (règle 'séparés par virgule' mentionnée mais format exact non spécifié).

#### #14746 — new prompt, prod: `unclear`

- La description demande un envoi mensuel automatique par email, mais le dernier commentaire (Bryan ALVES, 2026-06-29) retient une interface utilisateur permettant de choisir une période jusqu'à 1 mois. Ce même commentaire mentionne pourtant une adresse email de destination (<client address>). Est-ce que la sortie attendue est : (a) un téléchargement direct du fichier Excel depuis l'interface, (b) un envoi automatique par email vers <client address> déclenché depuis l'interface après choix de la période, ou (c) les deux ?
- Où doit se trouver cette nouvelle interface de sélection de période dans l'application (quel menu / quelle page) ? Le ticket ne précise pas l'emplacement.
- Qui a accès à cette interface d'export ? Uniquement les utilisateurs de la société RAD, ou tous les comptes (avec filtre), ou un rôle particulier (support / admin) ? Emily a soulevé le fait qu'une interface cachée à tout le monde sauf eux pose problème, mais la décision finale sur la visibilité n'est pas tranchée.
- La fonctionnalité est-elle exclusive à la société RAD (ID 471) ou doit-elle être disponible pour toute société, avec RAD comme premier bénéficiaire ? Le commentaire du 2026-06-29 ne cite que RAD mais ne dit pas si l'implémentation doit être génériquement activable ailleurs.

#### #14746 — new prompt, prod#2: `unclear`

- La description demande un envoi mensuel automatique par email, mais le commentaire de Bryan ALVES du 2026-06-29 mentionne à la fois une adresse email de destination (<client address>, point 2) ET une interface utilisateur permettant de choisir une période (point 3) : s'agit-il d'un envoi automatique par email, d'un export téléchargeable via une interface, ou des deux ? Si envoi par email, à quelle fréquence et avec quelle période (mois civil écoulé) ?
- Si une interface utilisateur est bien retenue, où se place-t-elle exactement dans l'application (quel menu, quelle page) et qui y a accès ? Emily Betham a soulevé le problème d'une interface cachée à tout le monde sauf à la société RAD, et aucune décision finale n'est tranchée sur la restriction d'accès (feature flipping limité à la société 471 - RAD, droit spécifique, visibilité globale ?).
- Pour le champ 'Date de la facture' / 'Date d'envoi de la facture' : Emily Betham a posé une question explicite (2025-09-24) sur la date de référence à utiliser (date de création vs date de facturation, à cause de l'antidatage) et Bryan a répondu 'Date de création de la facture oui' — mais le ticket contient à la fois 'Date de la facture' et 'Date d'envoi de la facture' comme champs distincts : laquelle est la date de création et comment est calculée 'Date d'envoi de la facture' ?

#### #14746 — new prompt, prod#3: `unclear`

- La description initiale demande un envoi mensuel automatique par email, mais le commentaire du 2026-06-29 ajoute une interface utilisateur pour choisir une période (jusqu'à 1 mois). Est-ce que la sortie attendue est : (a) un fichier téléchargé directement depuis l'interface, (b) un email envoyé à <client address> déclenché depuis l'interface, ou (c) les deux ? L'adresse email est mentionnée mais sa fonction avec l'interface n'est pas précisée.
- L'emplacement de l'interface dans l'application n'est pas précisé : où doit-elle se trouver (page société RAD, menu dédié, section gestion commerciale, autre) ?
- Qui a accès à cette interface d'export : les utilisateurs internes Powerpanne, les utilisateurs de la société RAD uniquement, un profil/droit spécifique ? L'interface doit-elle être restreinte à la société 471 - RAD ou disponible pour toutes les sociétés ?

#### #14746 — new prompt, prod#4: `unclear`

- La description initiale decrit un envoi mensuel automatique du rapport Excel, mais le commentaire final (2026-06-29) demande 'une interface utilisateur permettant de choisir une periode jusqu'a 1 mois'. Le ticket conserve aussi une adresse email de destination (<client address>). Faut-il : un ecran d'export avec telechargement du fichier, un envoi par email a <client address> apres selection de la periode, ou les deux ?
- L'emplacement de l'interface d'export dans l'application n'est pas precise. Ou doit-elle etre accessible (menu, page societe RAD, gestion commerciale, autre) ?
- Qui a acces a cette interface n'est pas specifie. Est-elle reservee aux utilisateurs de la societe RAD (company 471) uniquement, ou disponible plus largement (feature flag, droit specifique) ? Emily avait souleve en commentaire la gene de cacher une interface 'a tout le monde sauf eux' sans que la decision finale soit tranchee.
- Pour le champ 'N° mission si AVA / si non → adresse postale' : la regle de bascule entre numero de mission et adresse postale (quel critere exact distingue une mission AVA d'une autre dans l'export) n'est pas explicitee au-dela de l'exemple fourni.

#### #14746 — new prompt, prod#5: `unclear`

- La sortie attendue est contradictoire : le commentaire final liste à la fois une « adresse email de destination (<client address>) » et une « interface utilisateur permettant de choisir une période jusqu'à 1 mois ». Après que la période est choisie dans l'UI, l'Excel est-il téléchargé par l'utilisateur, envoyé par email à <client address>, ou les deux ?
- L'emplacement de l'interface utilisateur dans l'application n'est pas précisé : où doit-elle apparaître (dans la gestion commerciale de la société RAD, dans un menu dédié, sur la page missions /companies/r-a-d/missions, ailleurs) ?
- Les droits d'accès à cette interface ne sont pas définis : qui peut la voir et l'utiliser (tous les utilisateurs de la société RAD, un profil spécifique, un feature flag) — sachant qu'Emily avait soulevé le problème « caché à tout le monde sauf eux » sans qu'une décision soit tranchée ?

#### #14746 — new prompt, default: `unclear`

- Le dernier commentaire (2026-06-29, option « (b) ») transforme l'envoi mensuel automatique de la description (« Demande d'envoi mensuel d'un rapport ») en une interface où l'utilisateur choisit une période d'un mois au plus. L'envoi automatique mensuel est-il abandonné, ou faut-il garder les deux (envoi automatique et export à la demande) ?
- Sortie de l'export à la demande : le même commentaire donne une adresse de destination (<client address>) et demande aussi une interface de sélection de période. Quand l'utilisatrice lance l'export depuis l'interface, le fichier Excel doit-il être téléchargé directement dans le navigateur, envoyé par email à <client address>, ou envoyé à l'email de l'utilisateur connecté ?
- Emplacement de l'interface : sur quel écran faut-il placer le formulaire de choix de période ? Par exemple dans la gestion commerciale à côté des exports existants, dans la page des missions de la société (/companies/r-a-d/missions), ou sur une nouvelle page dédiée ?
- Accès : qui peut utiliser cet export ? Emily BETHAM a signalé le 2026-02-18 qu'une interface cachée à tous sauf RAD posait problème, et rien n'a été tranché depuis. L'export est-il réservé à la société 471 - RAD (feature flag ou feature de la FeatureTree activée pour elle seule), ou ouvert à toutes les sociétés ? Et quels utilisateurs ou droits y ont accès ?
- Date de référence de la période : Bryan ALVES a confirmé le 2025-09-24 « Date de création de la facture », mais c'était avant le passage à une période libre. Le filtre de période porte-t-il toujours sur la date de création de la facture, et non sur la date de facturation, la date d'envoi ou la date d'intervention ?

#### #16341 — new prompt, prod: `unclear`

- La phrase « il devra être disponible pour les imprts de règlements également » est ambiguë : s'agit-il d'un export de règlements au format FEC (pattern `Compta::XxxxPayments` existant) ou d'un import de règlements à partir d'un fichier FEC fourni par le client ? Le mot « imprts » peut être une coquille pour « imports » ou « exports », et l'implémentation diffère complètement selon le cas.
- Si « imprts de règlements » signifie import de règlements : le ticket ne décrit ni le format du fichier attendu en entrée, ni le mapping des 18 colonnes FEC vers les règlements Powerpanne (quels comptes sont considérés comme règlements, comment relier une ligne à une facture existante, que faire des lignes non reconnues), ni l'écran où déclencher l'import.
- Si « imprts de règlements » signifie export de règlements au format FEC : le ticket ne précise pas quels comptes/journaux doivent être utilisés pour les règlements (code journal « BQ », « CA » ou autre ? comptes 512xxx ? 411xxx en contrepartie ?), ni si l'export réutilise exactement les 18 mêmes colonnes.

#### #16522 — old prompt, prod: `unclear`

- La couleur cible n'est pas specifiee textuellement (ni code hex, ni variable SCSS/token). Le ticket renvoie a une capture d'ecran de 'la police sur laquelle te baser', mais sans valeur chiffree ni reference a un element existant identifiable (ex: 'meme couleur que les labels de la page X'), impossible de choisir sans ambiguite entre plusieurs variables du design system ($gray-800, $gray-900, $primary-500, etc.).
- Portee ambigue : la demande vise les labels 'immatriculations', 'n° de facture', etc. (classe .custom-form-label dans le haut du formulaire), mais la mention 'etc' laisse flou si cela doit aussi s'appliquer aux labels des sections collapsables (Montant HT, Clients, Diagnostic, etc.) qui utilisent un autre style (.collapse-content label avec color: $secondary).

#### #16580 — old prompt, prod: `unclear`

- La forme exacte de l'indicateur visuel sur la page de dispatch n'est pas spécifiée — le ticket ne donne qu'un exemple (« une couleur ou un élément graphique spécifique ») sans préciser s'il s'agit d'un badge, d'une icône, d'une colorisation de la ligne, et sans préciser l'emplacement ni le libellé.
- Le ticket ne précise pas s'il faut distinguer visuellement « annulation » et « proposition d'annulation » sur le dispatch, alors qu'il s'agit de deux états différents mentionnés dans le résultat attendu.
- Le comportement de la modale de missionnement pour une annulation déjà confirmée (par opposition à une proposition d'annulation) n'est pas spécifié — seul le cas « proposition d'annulation » est décrit (bandeau rouge + masquage des dépanneurs).
