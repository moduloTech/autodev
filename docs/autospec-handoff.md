# AutoSpec — Handoff

**Last updated:** 2026-06-16 (after the hourly project briefing — phase D + briefing addon shipped)
**Canonical plan:** [`autospec.md`](autospec.md) §C (12-step attack order, marked ⬜/✅)
**Latest release tag:** `v1.0.0-alpha.17` (phase D complete + project-briefing addon — 5 commits ahead of origin/master, unpushed; ready to cut `v1.0.0-alpha.18`)

This document is the *resume-anywhere* state of phase D (AutoSpec). It assumes
you have **no memory of previous sessions** and gives you:

1. Where we are on the plan (which steps shipped, which remain).
2. The architectural shape *right now* — what owns what, where the code lives.
3. The pattern to apply for the next slices.
4. Decisions + gotchas that bit us — not in `autospec.md`.
5. Fresh-session sanity checks to run before changing anything.

When in doubt about *intent*, [`autospec.md`](autospec.md) is authoritative.
When in doubt about *current state*, run the sanity checks in §5.

When in doubt about who's responsible for the *visual* details, see
[`docs/design/spec_update/README.md`](design/spec_update/README.md) — the
HTML/JSX reference under `design/spec_update/reference/` is the source of
truth for layout/spacing/colors.

---

## 0. Terminology — phase D / step / slice

`autospec.md` §C numbers 12 steps total (railsification + users-rollout +
AutoSpec). **Phase D = AutoSpec proper, steps 9–12.** During execution,
step 9 and step 10 got sliced into sub-units because each spans multiple
sessions:

| Slice | Scope | Status |
|---|---|---|
| **9** | Backend: schema, models, Chat service, suggestion applier, markdown patcher | ✅ done at SHA `fd5b9c6` (3 internal sub-slices 9a/9b/9c bundled into one commit) |
| **10a** | Frontend backbone: index/new/create/show, sidebar entry, CTA wire-ups | ✅ done at SHA `d2db3d6` |
| **10b** | Markdown editor (toggle Édition/Aperçu, ⌘+B/I/K, autosave) + meta-chip editing + title editing + two-column desktop layout | ✅ done at SHA `b286915` |
| **10c** | Drag-drop attachments via ActiveStorage + AttachmentCard grid + mobile responsive (tabs) + dark-mode polish | ✅ done at SHA `566cf41` |
| **11** | Workflow approbation: owners' encart, vote orchestration, GitLab issue creation pipeline | ✅ done at SHA `d4c46f3` |
| **12** | Import an existing GitLab issue as a draft (lowest priority — §A "very nice to have") | ✅ done at SHA `173c90c` |
| **briefing** | Hourly project briefing — clone `staging` + `danger-claude -p` + cached system-prompt block. Post-phase-D addon. See [`autospec.md`](autospec.md) §M. | ✅ done at SHA `b0f21cd` |

The sub-slice names (9a/9b/9c) are historical — they all live in one
commit now. Use them in commit messages or PR titles only if you want
to be precise about WHICH part of step 9 you're touching.

---

## 1. State at this commit

```
b0f21cd feat(autospec): hourly project briefing — staging clone + danger-claude   ← HEAD
173c90c feat(autospec): GitLab issue import (step 12) — phase D complete
d4c46f3 feat(autospec): workflow approbation + GitlabSubmitter (step 11)
566cf41 feat(autospec): drag-drop attachments + mobile tabs (step 10c)
b286915 feat(autospec): editor + autosave + missing-key handling (step 10b)
6904257 docs(autospec): add handoff doc for resuming phase D work across sessions
e4133fb fix(web): emit CSRF token on Phlex forms — form_authenticity_token is private
d2db3d6 feat(autospec): frontend backbone (step 10a) + CTA wire-ups
fd5b9c6 feat(autospec): backend (step 9) — schema, models, chat service, suggestion applier
4da1007 docs(autospec): refresh plan after railsification + users-rollout
da2ce03 Release v1.0.0-alpha.17   ← latest tag, master HEAD before phase D
```

5 commits ahead of `origin/master`, unpushed. **Phase D functionally complete end-to-end + briefing addon shipped — ready to cut `v1.0.0-alpha.18`.**

Mapping to [`autospec.md`](autospec.md) §C + addon:

| Step | Title | Status |
|---|---|---|
| **9** | Backend AutoSpec | ✅ done (`fd5b9c6`) |
| **10** | Frontend AutoSpec | ✅ done (10a `d2db3d6`, 10b `b286915`, 10c `566cf41`) |
| **11** | Workflow approbation | ✅ done (`d4c46f3`) |
| **12** | Import GitLab d'un ticket existant | ✅ done (`173c90c`) |
| addon | Project briefing (autospec.md §M) | ✅ done (`b0f21cd`) |

The CSRF fix in `e4133fb` is independent — see §4 for the root cause.

---

## 2. Architectural shape *right now*

### Entry points (user)

- Sidebar → "Conversations" → `/autospec_drafts` (index)
- Dashboard / `/issues` / `/projects/:slug` topbar → "Nouvelle demande" → `/autospec_drafts/new`
- Sidebar bottom CTA card "Démarrer" → `/autospec_drafts/new`

All four CTAs landed in step 10a — they were `coming-soon` placeholders before.

### Data layer

Four tables under primary DB:

| Table | Role | Notable columns |
|---|---|---|
| `autospec_drafts` | One ticket-in-the-making | `status` (string, AASM), `current_iteration`, `meta_chips` JSON, `destination` enum nullable, GitLab pointer fields |
| `autospec_messages` | Conversation log | `role` ('user' / 'assistant'), `content` text, `tool_calls` JSON array |
| `autospec_attachments` | Captures anchor | Thin AR row; `has_one_attached :file` (ActiveStorage) |
| `autospec_approvals` | Owner votes | `iteration` snapshot, `action` ('approved' / 'rejected'), `reason` (required if rejected), unique index `(draft, user, iteration)` |

Plus the standard ActiveStorage triple (`active_storage_{blobs,attachments,variant_records}`).

`Issue` patterns reused: AASM on a string column, JSON columns via
`attribute :col, :json, default: ...`, `if_not_exists: true` on every
migration.

### Service layer (`app/services/autospec/`)

| Service | Responsibility |
|---|---|
| `Tools` | 4 JSON schemas for the Anthropic Messages API — `propose_markdown_patch` (default), `propose_full_rewrite` (discouraged), `propose_title`, `propose_meta_change`. `Tools::ALL` ships every chat turn. |
| `SystemPrompt` | Builds the `system:` payload — 2 blocks: persona+guidance (`cache_control: { type: 'ephemeral' }`) + draft state (uncached, changes on edit). |
| `MessageBuilder` | Translates AR `autospec_messages` → Anthropic API shape. Synthesises `tool_result` blocks from `applied_at` stamps (autospec.md §G "strict feedback"). |
| `Chat` | One chat turn: persist user → request → parse content (text + tool_use) → persist assistant. Default model `claude-sonnet-4-6`. API key resolves from `ENV['ANTHROPIC_API_KEY']` then `~/.autodev/config.yml` `anthropic.api_key`. SDK loaded lazily via `require 'anthropic'` inside `#build_default_client`. |
| `SuggestionApplier` | Idempotent: applies a tool_use to the draft (markdown patch / full rewrite / title / meta) + stamps `applied_at`. Raises `AlreadyApplied`, `ToolUseNotFound`, `UnsupportedTool`. |
| `MarkdownPatcher` | 4 ops (append_to_end, create_section, insert_after_heading, replace_section) with case-insensitive + whitespace-trimmed heading matching; falls back to `append_to_end` on miss and reports `fell_back?` in the Result struct. |
| `MarkdownRenderer` | Thin Redcarpet wrapper used by the Aperçu pane of the editor + the `preview_html` field in the PATCH JSON response. **`escape_html: true`** (user content, contra `HelpDoc` which renders trusted in-app docs). Tables intentionally absent at MVP. |
| `ApprovalRecorder` | Records one owner vote (approve / reject) per draft per iteration, atomically. On rejection → `mark_rejected!`. On approval, if every owner has an `approved` row at `current_iteration` → calls `GitlabSubmitter#submit!` then `finalize!`. Raises `NotAnOwner`, `AlreadyVoted`, `DraftNotPending`. |
| `GitlabSubmitter` | At finalize: uploads each AutospecAttachment blob via `client.upload_file(project_path, tmp_path)`, rewrites the draft markdown to swap `/rails/active_storage/...` URLs for the returned GitLab `/uploads/...` paths, then `client.create_issue(project_path, title, description:, labels:)`. `labels_todo` from the project config is sent only when `destination == 'autodev'`. Stamps `gitlab_issue_iid` + `gitlab_issue_url` + `submitted_at`. **Test seam:** `Autospec::GitlabSubmitter.disabled = true` makes `#submit!` a no-op (the workflow tests use this). |
| `GitlabImporter` | Step 12 backfill path: parses a GitLab issue URL (`https://host/group/.../proj/-/issues/N`, supports nested namespaces + trailing slashes/queries), looks up the matching `Project` row, checks `user.contributor_of?(project)` (admin bypass), fetches via `client.issue(path, iid)`, creates an `AutospecDraft` pre-populated with `title` + `description`. Raises `InvalidUrl`, `ProjectNotFound`, `ProjectNotVisible`, `IssueNotFound`. **Test seam:** `Autospec::GitlabImporter.default_client = stub` (same pattern as `Autospec::Chat.default_client`). |
| `ProjectBriefer` | Hourly project briefing generator (post-phase-D addon). Shallow-clones the project's `staging` branch (fallback to remote HEAD via `git ls-remote --symref`) into a `Dir.mktmpdir`, invokes `danger-claude -p <prompt>` with the work_dir as cwd, stores the markdown output on `Project.briefing_text` + stamps `briefing_generated_at`. Failure: stamps `briefing_error`, keeps stale `briefing_text` intact (a stale briefing beats no briefing). Triggered by `RefreshProjectBriefingsJob` from `config/recurring.yml` (`0 * * * *`). Read at chat time by `SystemPrompt#project_briefing` and injected as a 2nd cached block of the system prompt. **Test seam:** `Autospec::ProjectBriefer.stub_invoker = ->(work_dir, prompt) { … }` bypasses the danger-claude shell-out. |

### HTTP layer

| Route | Action | Notes |
|---|---|---|
| `GET /autospec_drafts` | `#index` | Lists `current_user.autospec_drafts` |
| `GET /autospec_drafts/new` | `#new` | Form scoped to `current_user.visible_projects` |
| `POST /autospec_drafts` | `#create` | Rejects project_id outside visibility |
| `GET /autospec_drafts/:id` | `#show` | Two-column workspace (editor + chat). Loads `/assets/js/autospec.js`. Renders attachments via `@draft.autospec_attachments.with_attached_file`. |
| `PATCH /autospec_drafts/:id` | `#update` | Autosave from the editor (title, markdown, meta_chips). `respond_to`: HTML redirect / JSON. **409 if not in `drafting`** (edits frozen once submitted; author must `retract!` first). `meta_chips` is server-side sliced to `META_KEYS` ∩ permitted keys. |
| `POST /autospec_drafts/:id/chat` | `#chat` | `respond_to`: HTML redirect / JSON. 503 if Anthropic key missing. |
| `POST /autospec_drafts/:id/apply_suggestion` | `#apply_suggestion` | `respond_to`: HTML redirect / JSON (409 on re-apply, 404 if tool_use_id absent) |
| `POST /autospec_drafts/:autospec_draft_id/autospec_attachments` | `AutospecAttachmentsController#create` | Multipart upload. Returns 201 + serialised `{id, filename, byte_size, width, height, url, markdown_snippet}`. 415 on bad content-type, **413** (`:content_too_large`) on >10 MB, 400 if `:file` absent. |
| `DELETE /autospec_drafts/:autospec_draft_id/autospec_attachments/:id` | `AutospecAttachmentsController#destroy` | 204 on success. |
| `POST /autospec_drafts/:id/submit_for_approval` | `#submit_for_approval` | Author transition `drafting → pending_approval`. Body `destination` ∈ `human`/`autodev` (the `autodev` choice is owner-only — §J). 409 if not drafting, 403 if destination forbidden for the user's role, 422 if destination value invalid. |
| `POST /autospec_drafts/:id/retract` | `#retract` | Author transition `pending_approval → drafting`. Iteration NOT decremented (audit-trail invariant). 409 if not pending_approval. |
| `POST /autospec_drafts/:id/approve` | `#approve` | Owner records an approval vote (via `Autospec::ApprovalRecorder`). 403 if not an owner / not pending, 409 if already voted at current iteration. Quorum reached (every owner approved at `current_iteration`) triggers `GitlabSubmitter` then `finalize!`. |
| `POST /autospec_drafts/:id/reject` | `#reject` | Owner records a rejection vote with a mandatory `reason`. 422 if reason empty. First rejection at current iteration flips the draft straight to `rejected`. |
| `GET /autospec_drafts/import` | `#import` | Form to paste a GitLab issue URL for backfill. |
| `POST /autospec_drafts/import` | `#create_from_import` | Creates a draft from the URL via `Autospec::GitlabImporter`. Stable error keys on failure: `import_invalid_url`, `import_project_not_found`, `import_project_not_visible`, `import_issue_not_found` (all redirect back to the form with `flash[:alert]`). |

Mounted via `resources :autospec_drafts, only: %i[index new create show update]`
+ six `:member` POSTs (chat, apply_suggestion, submit_for_approval, retract,
approve, reject) + nested `resources :autospec_attachments`. Auth gates per §J
matrix:

- `show` → `authorize_view!` (admin OR author OR owner+post-submit).
- `approve` / `reject` → `authorize_voter!` (owner of project + draft in pending_approval).
- everything else → `authorize_author!` (author equality on draft.user_id).

Per-action state guards return **409 Conflict** distinct from 403:
- `update` if not drafting.
- `submit_for_approval` if not drafting.
- `retract` if not pending_approval.
- `approve` if already voted at current iteration (via `ApprovalRecorder`).

Token-level SSE deferred per autospec.md §L — `#chat` is synchronous
JSON. Rebinding to `ActionController::Live` + the SDK's
`messages.stream(…)` is ~30 LOC when step 10b/10c proves the
typing-effect UX is worth it.

### View layer (`app/components/web/views/autospec_drafts/`)

- `Index` — list of drafts, empty state, "Nouveau brouillon" CTA
- `New` — project picker + title + initial markdown
- `Show` — two-column workspace (10b): editor column (sticky toolbar
  with Édition|Aperçu tabs + format buttons + save indicator → meta
  chips row → inline title input → markdown textarea OR server-rendered
  preview pane → footer hint) + chat column (380 px desktop, 320 px
  tablet) keeping the 10a conversation card content (messages +
  composer + apply buttons per tool_call, disabled when `applied_at`
  set). Mobile-tabs layout (Édition | Discussion) is 10c.

All three extend `Web::Views::Base` and reuse `Components::{Card,
Sidebar, Topbar}`. The `csrf_input_tag` helper on Base emits the
hidden authenticity_token input — see §4 for the fix story.

### Frontend JS (`/assets/js/autospec.js`)

Step 10b ships a small vanilla-JS module loaded by the Show view (`<script
defer>` at the end of the page). Served via `AssetsController` from
`app/assets/static/js/autospec.js` (Propshaft load_path). Responsibilities:

- Tab toggle Édition ↔ Aperçu — hides/shows the two `[data-autospec-pane]` nodes.
- Format buttons (B / I / `</>` / H / list / quote / link) — caret-aware insertion via `selectionStart/End`.
- Keyboard shortcuts: ⌘+B / ⌘+I / ⌘+K (link) + ⌘+Enter flushes the autosave debounce.
- Autosave with **2 s debounce**: PATCH `/autospec_drafts/:id` carrying the dirty fields (`title`, `markdown`, `meta_chips`). The JSON response updates the preview pane's HTML in place.
- localStorage backup keyed `autodev:draft:<id>:<field>` (markdown, title, meta_chips). On load, any value differing from the server-rendered input is restored + immediately queued for save. Cleared after each successful PATCH.
- Save indicator (idle / saving / error / locked) via `data-state`. The label dictionary is built once from the initial server-rendered text via an FR/EN heuristic — fine because locale doesn't switch mid-page.
- Meta-chip inline edit: click a chip → swap value span for a `<select>` (when `data-autospec-chip-options` is set, e.g. type/priority) or `<input>` (tags, comma-separated). Commit on blur / Enter, Escape cancels.
- Drag-drop attachments (step 10c): listen for `dragenter / dragover / dragleave / drop` on the editor column with a depth counter (descendant `dragenter`/`leave` pairs cancel out); on drop, multipart POST per file to the attachments endpoint, then `appendAttachmentCard` mutates the grid (inserted before the perpetual drop-target slot so it stays last). Event delegation handles ✕ (DELETE → remove card) and ⧉ (copy `data-autospec-attachment-markdown` to clipboard, brief "copied" state via `data-state="copied"`).
- Mobile tabs (step 10c): below 960 px, the workspace's `data-autospec-active-tab` attribute drives which of editor-col / chat-col is `display: none`. The tab bar itself is `display: flex` only inside the same media query.

### Test surface

| Area | File(s) | Count |
|---|---|---|
| Models | `test/models/autospec_*.rb` (5 files) | 32 |
| Services | `test/services/autospec/*.rb` (11 files incl. `project_briefer_test.rb` + 3 briefing tests on `system_prompt_test.rb`) | 85 |
| Controllers (JSON drafts) | `test/controllers/autospec_drafts_controller_test.rb` | 29 |
| Controllers (HTML drafts) | `test/controllers/autospec_drafts_html_test.rb` | 18 |
| Controllers (attachments) | `test/controllers/autospec_attachments_controller_test.rb` | 9 |
| Controllers (import) | `test/controllers/autospec_drafts_import_test.rb` | 5 |
| Controllers (dashboard banner) | `test/controllers/dashboard_anthropic_banner_test.rb` | 3 |
| Controllers (dashboard owner widget) | `test/controllers/dashboard_owner_widget_test.rb` | 4 |
| **Total added at phase D + briefing** | | **185** |

Suite total at HEAD: **734 runs, 1368 assertions, 0 failures**.

---

## 3. Pattern for the next slices

### Step 10b — markdown editor + meta chips + title editing + two-col layout — ✅ done

**What landed**:

- Two-column workspace in `Web::Views::AutospecDrafts::Show`: editor centre (max-width 820 px, `autospec-editor-col`) + chat right (`autospec-chat-col`, 380 px desktop / 320 px tablet / collapsed under 960 px). CSS lives in `app/assets/static/css/app.css` under the `/* ── AutoSpec editor workspace ──` block.
- Sticky toolbar with pill-style Édition|Aperçu tabs, format buttons (B / I / `</>` / H / list / quote / link 🔗), and save indicator (idle / saving / error / locked).
- Inline title input (26 px / 600 — slightly smaller than the design's 28 px to leave room next to the chips), markdown textarea (mono 13.5 px, min-height 320 px), server-rendered preview pane (hidden by default; toggled via `hidden` attribute by JS).
- Meta-chip editing for `type`, `priority` (selects with `bug/feature/improvement` and `low/medium/high/critical` from locale strings), `tags` (free-text comma-separated input). Static read-only chips for `status` + `iteration` follow the editable ones. **No `assignee` chip** — `Autospec::Tools::META_CHANGE` explicitly excludes it ("assignment stays a human decision"), and `SuggestionApplier::META_KEYS` matches.
- Vanilla-JS module at `app/assets/static/js/autospec.js` (served via `/assets/js/autospec.js`) handling toggle / shortcuts / autosave / localStorage / chip editing. No build step.
- New `Autospec::MarkdownRenderer` service (Redcarpet with `escape_html: true`) used by both the server-rendered preview pane AND the `preview_html` field included in the PATCH JSON response — autosave refreshes the preview in place.
- New PATCH `/autospec_drafts/:id` endpoint with strong params (`:title, :markdown, meta_chips: [:type, :priority, { tags: [] }]`), server-side `slice` against `META_KEYS` for defence in depth, **409 + `error: 'draft_locked'` when the draft is not in `drafting`** (autosave loop reacts by disabling inputs and switching the indicator).
- 14 new tests (6 renderer, 6 update JSON, 2 update HTML).

**What's deferred to 10c** (covered below): drag-drop attachments, the mobile **Édition | Discussion** tabs layout, dark-mode polish on the new components, the explicit "Créer le ticket" button + ⌘+Enter submit (currently ⌘+Enter just flushes the autosave debounce — the actual submit transition is step 11 work).

### Step 10c — drag-drop attachments + responsive — ✅ done

**What landed**:

- `AutospecAttachmentsController` with `POST` (multipart) + `DELETE` actions, nested under `resources :autospec_drafts`. Validates content-type against `image/(png|jpe?g|gif|webp)` and size ≤ 10 MB (`:content_too_large`, the `:payload_too_large` symbol is deprecated in Rack 3 / Rails 8.1 — heads up). Returns serialised JSON `{id, filename, byte_size, width, height, url, markdown_snippet}` for each attachment.
- AttachmentCard grid below the markdown editor (220 px `minmax(auto-fill)` columns, ✕ button top-right, footer with filename + size + copy-markdown ⧉ button). Perpetual `autospec-drop-target` slot at the end of the grid so the affordance is always visible, even with zero attachments. Clicking it opens a native file picker.
- Full-column dropzone overlay (`autospec-dropzone-overlay`) covering the editor column, toggled by JS via `data-active="true"` on dragenter and back to `"false"` on dragleave / drop. `pointer-events: none` so it never swallows real input — purely visual.
- Mobile tabs **Édition | Discussion** at ≤ 960 px. The CSS grid stays single-column at that breakpoint but now hides the inactive column entirely (`display: none` controlled by `data-autospec-active-tab` on the workspace). On desktop the tab bar itself is `display: none`.
- Dark-mode polish: all new components reuse the existing `--paper`, `--paper-2`, `--border`, `--border-strong`, `--text-strong`, `--text-muted`, `--accent-*`, `--err-*`, `--ok-*`, `--shadow-{xs,md}` tokens which already have dark variants in `tokens.css`. No new tokens introduced.
- 9 new tests: 7 create (auth, forbid non-author, persists, serialised payload, missing-file, bad mime, oversized) + 2 destroy (success, forbid).
- **Width / height not populated** at the MVP. ActiveStorage's analyzer requires either `mini_magick` or `ruby-vips`, neither of which is in the Gemfile. The metadata stays empty; the UI degrades gracefully (size shown alone). Bring `mini_magick` in if dims become important — `serialise` already passes `blob.metadata['width']` / `'height'` through, so a single gem add lights the feature up without code changes.

**Submission-time pipeline** (step 11's GitlabSubmitter): download each blob, upload via GitLab's `POST /api/v4/projects/:id/uploads`, rewrite the markdown to swap `/rails/active_storage/...` URLs for the returned GitLab URLs. The card stores the original `![filename](/rails/...)` snippet in `data-autospec-attachment-markdown`, which the copy button reads — at submission time the submitter rewrites whatever the editor's markdown body contains, regardless of where the user pasted the snippet.

### Step 11 — workflow approbation — ✅ done

**What landed**:

- Permission helpers on `AutospecDraft` (model): `viewable_by?`, `editable_by?`, `submittable_by?`, `destination_choosable_by?`, `retractable_by?`, `votable_by?` — encode the §J matrix combining role + author + state. Controllers and the Show view call them.
- 4 new controller actions: `#submit_for_approval` (with `destination` param + the `autodev`-is-owner-only gate), `#retract`, `#approve`, `#reject` (with mandatory `reason`). The before-action chain split into `authorize_view!` (show), `authorize_voter!` (approve/reject), and the existing `authorize_author!` (everything else).
- New `Autospec::ApprovalRecorder` service: atomic record-then-decide. Rejection → `mark_rejected!` (transitions to `rejected`); approval, when quorum (every owner approved at the current iteration) is met → calls `GitlabSubmitter#submit!` then `finalize!`. Idempotent at the (draft, user, iteration) tuple — `AlreadyVoted` raised on a second attempt.
- New `Autospec::GitlabSubmitter` service: streams each blob to a `Tempfile`, calls `client.upload_file(project_path, tmp_path)`, naive-substring-replaces every local `/rails/active_storage/...` URL in the draft markdown with the returned GitLab `/uploads/...` URL, then `client.create_issue(project_path, title, description:, labels:)`. `labels_todo` from the matching project_config entry is sent only when `destination == 'autodev'`. Stamps `gitlab_issue_iid`, `gitlab_issue_url`, `submitted_at`. **Test seam:** `Autospec::GitlabSubmitter.disabled = true` short-circuits `#submit!` to a no-op (the ApprovalRecorder + controller + dashboard widget tests use this to avoid needing a stub gitlab client).
- Show view: "Créer le ticket" buttons in the topbar action slot (1 button labelled "Envoyer à un dev" for contributor-author, 2 buttons "Envoyer à un dev" + "Envoyer à AutoDev" for owner-author). "Rétracter" button when pending_approval + author. New **approval banner** at the top of the editor body for any non-drafting state — warn-tinted for `pending_approval`, err-tinted for `rejected`, accent-tinted for `submitted`. When the viewer is a voter (owner + pending_approval + not yet voted), the banner carries `[Approuver]` + a `[textarea required] [Rejeter]` inline form. Below the buttons, votes cast at the current iteration are listed with ✓/✗ + voter email + reason.
- Dashboard widget for owners (step 11c): a "Brouillons à valider" card on `/` listing drafts in `pending_approval` on owned projects where the user hasn't voted at the current iteration. Hidden entirely for non-owners (they can't act on anything). Reuses the active-issues card visual.
- 29 new tests across 4 files: 9 ApprovalRecorder (NotAnOwner / DraftNotPending / AlreadyVoted guards + quorum logic + iteration scoping), 7 GitlabSubmitter (happy path + URL rewrite + labels by destination + disabled flag + already-submitted guard), 13 controller (submit/retract auth + state, approve/reject auth + finalize, visibility matrix), 4 dashboard widget (admin/member/owner-with-vote/owner-without-project).

Reference: autospec.md §E (lifecycle diagram), §F (attachment upload at submission), §J (rôles matrix).

### Step 12 — GitLab import — ✅ done

**What landed**:

- `Autospec::GitlabImporter` service parses the GitLab issue URL (regex `\Ahttps?://[^/]+/(?<path>.+?)/-/issues/(?<iid>\d+)/?(?:[?#].*)?\z` — supports nested namespaces, trailing slashes, query/fragment), looks up the matching `Project` row by `gitlab_path`, checks user access (admin bypass + `contributor_of?`), fetches the issue via `client.issue(path, iid)`, creates an `AutospecDraft` pre-populated with the issue's `title` + `description`. 4 typed errors (`InvalidUrl`, `ProjectNotFound`, `ProjectNotVisible`, `IssueNotFound`) cover every rejection path.
- New routes on the existing resources block: `get :import` + `post :import → #create_from_import`. The controller maps each importer exception to a stable error key (`import_invalid_url`, `import_project_not_found`, `import_project_not_visible`, `import_issue_not_found`) and redirects back to the form with `flash[:alert]`. The before-actions skip-list grew to include the two new actions so neither `load_draft` nor `authorize_author!` fires for collection-route requests.
- New Phlex view `Web::Views::AutospecDrafts::Import` — single URL textfield with a `font-family: var(--font-mono)` styling cue, "Importer" submit + "Annuler" link back to the index.
- New "Importer depuis GitLab" secondary button on `/autospec_drafts` next to the primary "Nouveau brouillon" CTA so the path is discoverable.
- 8 service tests + 5 controller tests covering URL parsing variants (trailing slash, query string, nested namespace), permission matrix (no membership / admin bypass), and the four error-key redirects.

### Deferred work — to revisit if the pilot surfaces a need

Phase D + briefing addon is functionally complete end-to-end. The
following items were **explicitly deferred** during cadrage or
implementation — none of them block shipping, all are documented
here so a future session can pick one up without re-deriving the
rationale. Listed roughly by likely usefulness.

#### Likely to come up during pilot use

1. **Token-by-token streaming in the chat** — `#chat` currently
   returns synchronous JSON. `Autospec::Chat#reply` calls
   `client.messages.create(...)`; streaming uses
   `client.messages.stream(...)` instead. Rebinding the action to
   `ActionController::Live` + a `fetch`-with-ReadableStream client
   is ~30 LOC. Cadrage rationale + revisit-criteria in
   [`autospec.md`](autospec.md) §L; the §L thread-saturation concern
   doesn't apply (chat connections are short-lived during a single
   LLM response).

2. **Push notifications to owners + authors** — cadrage chose
   pull-only (encart dashboard + "Mes brouillons") for MVP, no
   email/Teams/webhook. AASM transitions already emit the events; a
   future Mailer or webhook job would subscribe to the same hooks.
   Cadrage rationale in [`autospec.md`](autospec.md) §K.

3. **Image dimensions in AttachmentCard footer** — `width/height`
   stay `nil` because ActiveStorage's image analyzer needs either
   `mini_magick` or `ruby-vips`, neither in the Gemfile. The
   serialiser already passes the metadata through (`blob.metadata
   ['width']`), so adding `gem 'mini_magick'` lights the feature up
   without code changes. Detailed in [`autospec.md`](autospec.md)
   §10c "what landed".

4. **Admin surface for `briefing_error`** — `projects.briefing_error`
   stores the last refresh failure but isn't displayed anywhere.
   Useful debug surface: add a column to `/admin/users` (or a
   `/admin/projects` page) showing per-project briefing status +
   last-error. Listed in [`autospec.md`](autospec.md) §M "limites
   connues".

5. **"Refresh briefing now" button per project** — currently a
   manual refresh requires `bin/rails runner 'Autospec::ProjectBriefer.
   new(Project.find(…)).refresh!'`. A POST admin route enqueuing
   `RefreshProjectBriefingsJob` for a single project_id would give
   a one-click path. Same source as item 4 (autospec.md §M).

6. **Per-iteration draft history** — when an owner rejects at
   iteration N, the author has no view of what was different between
   iteration N-1 and N. Could be useful for "what did I actually
   change between rejections?". Out of scope at cadrage; would need
   snapshot rows on every `submit_for_approval` transition. Not
   referenced in autospec.md — invented here, document if added.

#### Out of phase-D scope, not urgent

7. **Model code introspection from the chat** — explicitly written
   out of scope ([`autospec.md`](autospec.md) §G "Hors scope MVP"):
   "Tools d'introspection codebase (`read_file`, `list_files`):
   registre AutoDev, pas AutoSpec." The project briefing addon
   (§M) is the substitute — Claude sees a digest of the code rather
   than direct read access. If we ever want direct read access, the
   path is integrating the relevant `danger-claude` tools through
   the chat, not adding new schemas to `Autospec::Tools`.

8. **Multi-CSM concurrent on a single draft** — cadrage decision:
   "Threads per-user: un thread = un CSM. Pas de collaboration
   multi-CSM sur un même draft." ([`autospec.md`](autospec.md) §A
   "Modèle Claude"). If two CSM want to co-author a spec, they
   discuss offline and one drives. To lift this: would need
   ActionCable for live state sync + conflict resolution on
   markdown / meta_chips. Substantial work; only do if the pilot
   demonstrates a real need.

9. **"Mode autonome client"** — mentioned in the meeting CR but
   explicitly: "oublié pour le MVP" ([`autospec.md`](autospec.md)
   §A "Workflow d'approbation"). A client-facing surface where a
   non-CSM (e.g. the customer's own product owner) could open
   drafts. Big product / security implications; not on the
   radar until post-bêta.

10. **AutoDev migration to the API** (instead of `danger-claude
    -p`) — parked: "AutoDev reste sur Team le temps qu'AutoSpec se
    stabilise. La migration AutoDev → API est explicitement parquée
    dans le CR (post-bêta)." ([`autospec.md`](autospec.md) §A
    "Modèle Claude"). Quota considerations: would double the load
    on the Team seat unless AutoDev moves first.

#### Always-applicable next step

11. **Vocabulary tuning of the chat suggestions** — the persona
    prompt (`Autospec::SystemPrompt::PERSONA` + the briefing
    prompt in `ProjectBriefer::PROMPT`) is the highest-leverage
    knob. Iterate based on pilot CSM feedback (the wording of
    apply buttons, the format of the briefing, the questions
    Claude asks first). No code changes — yaml/string tweaks
    only.

---

## 4. Decisions + gotchas

**Not in `autospec.md`** — these were learned during execution.

### `form_authenticity_token` is private on ActionController::Base

The `view_kwargs` helper in `app/helpers/web/helpers.rb` originally used
`respond_to?(:form_authenticity_token)` (without `true`) to guard the
call. The method is **private** on ActionController::Base, so the
default `respond_to?` returned false and the helper silently set
`csrf_token: nil`. Every Phlex view that depends on `@csrf_token`
(Layout's meta tag, the sidebar sign-out hidden input, the
reset/transition forms, the AutoSpec forms) therefore omitted the
token. The sidebar sign-out kept working because
`Users::SessionsController#destroy` has `skip_forgery_protection only:
:destroy` — the rest 422'd on every POST since users-rollout PR3.

**Fix** (in `e4133fb`): pass `true` to `respond_to?`. One-line fix.

When you add a new POST endpoint, **trust** that the layout emits
`<meta name="csrf-token">` and that `csrf_input_tag` inside a Phlex
form emits the hidden input. They both depend on `@csrf_token` being
non-nil; the helper now provides it.

### `Autospec::Chat.default_client` class hook for tests

The chat controller calls `Autospec::Chat.new(@draft).reply(...)` —
no way to pass `client:` through. Tests need a stub client. The hook:

```ruby
class << Autospec::Chat
  attr_accessor :default_client
end
```

Tests set it in `setup` and clear it in `teardown`. Without that,
controller tests would need to stub-monkey-patch class methods. See
`test/controllers/autospec_drafts_controller_test.rb` for the pattern.

### AR `:json` shallow change detection + `tool_calls_will_change!`

The `:json` attribute type compares by **object identity** on dirty
check. Mutating an element inside the array (e.g.,
`tool_call['applied_at'] = ...`) does NOT mark the column dirty —
`save!` would no-op. `SuggestionApplier#stamp_applied!` calls
`@message.tool_calls_will_change!` explicitly to force AR to persist.
Same trap exists for `meta_chips` if step 10b mutates entries
in-place.

### Status column is a **string**, not an integer enum

`autospec.md` §E sketched `t.integer :status` for `autospec_drafts`. We
went with string for AASM consistency with `Issue` (which has been on
a string status column since the railsification). The trade-off: 4
extra characters per row × N drafts = negligible. The gain: same
column type means same Phlex helper `status_pill` / same i18n key
pattern.

### Streaming chat deferred (autospec.md §L)

Step 9c shipped `#chat` as synchronous POST + JSON. Token streaming
is deferred until step 10b can validate the UX. To enable it:

1. Add `Autospec::Chat#stream_reply(user_content:, &block)` using
   `client.messages.stream(...)`
2. Make `#chat` action `include ActionController::Live` and write SSE
   chunks
3. Frontend uses `fetch` + ReadableStream (NOT `EventSource` — that's
   GET-only) to consume

The §L thread-saturation concern doesn't apply the same way to chat
(short-lived connection during LLM response) as it does to the
dashboard SSE (long-lived event subscription). ActionCable + Solid
Cable migration remains an orthogonal decision for the dashboard.

### Queue adapter must be `:test` in test env

`config/environments/test.rb` sets `config.active_job.queue_adapter =
:test`. Without it, ActiveStorage's `AnalyzeJob` (fired on every
`Blob#attach`) hits Solid Queue, but `test/rails_helper.rb` only
migrates the primary DB — the queue DB stays empty → crash. The
`:test` adapter captures-without-running, which is also what the job
wiring tests want.

### Anthropic SDK gem is loaded lazily

`gem 'anthropic', '~> 1.4'` is in the Gemfile but `require 'anthropic'`
lives **inside** `Autospec::Chat#build_default_client`. Tests pass a
stub client via the constructor (or `default_client` hook) and never
trigger the require — keeps the test boot fast and isolated from
network-touching gem code.

### CSRF + Phlex forms inside Cards

I initially suspected that nesting a `<form>` inside
`render Components::Card.new do ... end` confused Phlex's block
context and dropped the `csrf_input_tag` output. **It didn't** — the
runner test showed the HTML was correct. The real issue was the
private-method `respond_to?` trap above. If you ever see a form with
no token, check `@csrf_token` first, NOT the Phlex block plumbing.

### `data-turbo="false"` was NOT the answer

Temporarily added then removed. The real fix is at the
`view_kwargs` level — once the token is emitted, Turbo Drive
serialises it correctly along with the rest of the form data. Don't
reach for `data-turbo="false"` as a CSRF workaround on AutoSpec forms.

### Edits only legal in `drafting` state — autosave must respect 409

PATCH `/autospec_drafts/:id` (`#update`) guards on `@draft.drafting?`
and returns **409 + `{ error: 'draft_locked' }`** otherwise. `autospec.js`'s
`flushSave` catches that, sets `ctx.locked = true`, disables both inputs,
and flips the save indicator to `locked`. If you change the lock policy
(e.g. allow edits during `pending_approval` with a "retract first?"
warning), update **both** the controller guard AND the JS error branch —
the indicator label dictionary uses `locked` as a state key, not a fragile
HTTP-status check.

### `meta_chips` is server-side sliced — never trust the form

The PATCH strong-params permit `meta_chips: [:type, :priority, { tags: [] }]`,
but the controller then runs another pass: `attrs[:meta_chips].slice(*META_KEYS)`.
Reason: a future tool (e.g. `propose_assignee`) might bump META_KEYS and
the strong-params list could fall out of sync, leaving stale fields the
model wouldn't understand. The slice keeps the JSON column matching
exactly what `SuggestionApplier` knows about. Mirror that pattern if you
add new editable meta fields.

### localStorage key includes the draft id

The design (`design/spec_update/README.md` §5) suggests
`autodev:draft:new` as the localStorage key. We use
**`autodev:draft:<id>:<field>`** instead — keyed by the draft's database
id so multiple tabs editing different drafts don't trample each other.
The `new` page (POST /autospec_drafts) doesn't currently autosave; once
the draft is created the user is redirected to `/autospec_drafts/:id`
and the JS picks it up from there. If you wire pre-creation autosave on
the `new` page, scope the key under `autodev:draft:new:<csrf-token>`
(or similar) to avoid the collision between two tabs starting new drafts.

### Missing Anthropic key is a 503, not a 500 — and surfaces in 3 places

The Anthropic API key resolution chain is `ENV['ANTHROPIC_API_KEY']` →
`Web.config.dig('anthropic', 'api_key')` → `Autospec::Chat.default_client`
(test seam). `Autospec::Chat.api_key_configured?` rolls all three into one
class-level predicate; the test seam intentionally counts as "configured"
so existing controller tests don't need to set ENV vars.

When the predicate returns false:

- `AutospecDraftsController#chat` short-circuits to **503 +
  `{ error: 'chat_unavailable' }`** (via `render_apply_error`). Without
  this guard, instantiating `Autospec::Chat#client` raises `ConfigError`
  and Rails default-rescues to a 500.
- `Web::Views::AutospecDrafts::Show` renders the chat composer with
  `disabled` on both the textarea and the send button, plus an inline
  warn-styled notice ("Chat indisponible") above the message list. The
  markdown editor + meta-chip editing still work — they have no
  Anthropic dependency.
- `Web::Views::Dashboard` renders an **admin-only** warn banner above
  the KPI grid linking to the config (`ANTHROPIC_API_KEY` env var or
  `~/.autodev/config.yml` `anthropic.api_key`). Non-admin users don't
  see it — they can't fix the key.

If you add a new endpoint that talks to Anthropic, gate it on
`api_key_configured?` and follow the same 503 pattern. Don't catch
`ConfigError` higher up — the predicate is the contract.

### GitlabSubmitter runs inside the ApprovalRecorder transaction

`ApprovalRecorder#apply_quorum_decision!` calls `GitlabSubmitter#submit!`
**before** `finalize!`, inside the same `ActiveRecord::Base.transaction`
that wraps the approval row creation. Rationale: if the GitLab API call
fails, we want to roll back the approval row + the AASM transition too,
so the user sees "Vote not recorded — retry" rather than "Vote
recorded but draft stuck in pending_approval forever."

The trade-off: a partial GitLab-side failure (`upload_file` succeeds
but `create_issue` raises) leaves orphan uploads on GitLab. Acceptable
for the MVP — operators can clean them up via the GitLab UI. A more
robust solution (idempotency keys, retry queue) is a step 12+ concern.

If you add another side-effect to the finalize path, decide whether it
belongs in the transaction (rollback-able) or after (fire-and-forget).

### Workflow test seam: `Autospec::GitlabSubmitter.disabled = true`

The ApprovalRecorder, controller, and dashboard-widget tests don't
want to stub the gitlab gem in every setup — there are too many entry
points. Instead, `Autospec::GitlabSubmitter.disabled` (class-level
flag, default `false`) makes `#submit!` an immediate no-op when set.
Tests that DO exercise the submitter directly (`gitlab_submitter_test`)
inject a stub client via the constructor and leave the flag alone.

Each test file that triggers the finalize path sets `disabled = true`
in `setup` and resets to `false` in `teardown`. **Forgetting the
teardown is the failure mode** — a stale flag would silently skip the
GitLab call in subsequent tests. The test file for the submitter
itself has its own per-test `ensure` block restoring the flag.

### Hourly project briefing — clone the `staging` branch, not main

The `RefreshProjectBriefingsJob` ticks every hour. For each `Project`,
it shallow-clones the **`staging`** branch (with a `git ls-remote --symref`
fallback to whatever the remote `HEAD` is — typically `main` / `master`)
into a `Dir.mktmpdir` and runs `danger-claude -p <prompt>` with the
work_dir as cwd. The briefing is stored on `Project.briefing_text` and
injected as a 2nd cached block of the AutoSpec chat system prompt by
`SystemPrompt#project_briefing`.

Rationale for `staging` over `main`: the briefing should reflect what
ships next, not what's been merged and is waiting for a release. If
a project doesn't follow the staging convention, the symref fallback
keeps things working without configuration.

Failure mode: keep the previous `briefing_text` intact, stamp the
error on `briefing_error`. The chat path is read-only and doesn't
care about staleness — a stale briefing beats no briefing.

Tests can't realistically shell out to `danger-claude`; use the
`Autospec::ProjectBriefer.stub_invoker = ->(work_dir, prompt) { … }`
class-level seam.

### `:payload_too_large` is deprecated — use `:content_too_large`

Rack 3 / Rails 8.1 renamed the 413 status symbol. `render status:
:payload_too_large` still works but emits a warning every test run.
`AutospecAttachmentsController#create` uses `:content_too_large`. If
you copy from older code in this repo (or upstream Rails examples)
that uses the old name, update it. Same trick may apply to other
renamed-in-Rack-3 symbols.

### Save-indicator label dictionary is built once, from initial text

`autospec.js`'s `setIndicator` switches the label text by reading from
a per-element `_dict` cache built on first call. The dictionary is
chosen via an FR-vs-EN heuristic on the **initial** server-rendered
label ("Enregistré" → FR, otherwise EN). That works because the locale
cookie doesn't change mid-page. If you ever introduce a runtime locale
switcher that updates the page in place without a reload, replace the
heuristic with an explicit `data-autospec-save-labels='{"idle": "…", …}'`
attribute populated server-side from the locale files.

---

## 5. Fresh-session sanity checks

Run these in order from a clean shell. If any fail, find the regression
before changing anything.

```bash
cd /home/claude/tooling/autodev

# 1. Right commit at HEAD
git log --oneline -1
# expect 'fix(web): emit CSRF token on Phlex forms' OR a later commit
# (the handoff doc itself should land as a docs commit too — adjust)

# 2. Schema in place
mise x ruby -- bin/rails runner '
  puts "tables: #{ActiveRecord::Base.connection.tables.grep(/autospec/).sort.inspect}"
  puts "draft AASM: #{AutospecDraft.aasm.states.map(&:name).inspect}"
' 2>&1 | tail -3
# expect: 4 autospec_* tables + active_storage_* + the 4 AASM states

# 3. AASM model tests
mise x ruby -- bundle exec rake test TEST=test/models/autospec_draft_aasm_test.rb 2>&1 | tail -3
# expect 12 runs, 0 failures

# 4. Full suite still green
mise x ruby -- bundle exec rake test 2>&1 | tail -3
# expect 734+ runs, 0 failures, 0 errors

# 5. Rubocop clean on the AutoSpec surface
mise x ruby -- bundle exec rubocop \
  app/controllers/autospec_drafts_controller.rb \
  app/models/autospec_*.rb \
  app/services/autospec/ \
  app/components/web/views/autospec_drafts/ \
  test/models/autospec_*.rb \
  test/services/autospec/ \
  test/controllers/autospec_drafts_*.rb 2>&1 | grep -E "(offenses|inspected)"
# expect 'no offenses detected'

# 6. End-to-end: with the dev server running on :4567, sign-in, then
# Sidebar → Conversations → "Nouveau brouillon" → submit → expect 302
# to /autospec_drafts/:id (not 422 CSRF — see §4).
```

---

## 6. Pointers

| If you want… | Look at |
|---|---|
| Plan + product decisions | [`autospec.md`](autospec.md) §A, §C, §E-G |
| Visual target for 10b/10c | [`design/spec_update/README.md`](design/spec_update/README.md) |
| Reference JSX prototype | [`design/spec_update/reference/screen-chat-spec.jsx`](design/spec_update/reference/screen-chat-spec.jsx) |
| Anthropic SDK docs | `https://github.com/anthropics/anthropic-sdk-ruby` (gem `anthropic ~> 1.4`, resolves to 1.48.1) |
| The chat service | [`app/services/autospec/chat.rb`](../app/services/autospec/chat.rb) |
| The 4 tool schemas | [`app/services/autospec/tools.rb`](../app/services/autospec/tools.rb) |
| The synthetic tool_result trick | [`app/services/autospec/message_builder.rb`](../app/services/autospec/message_builder.rb) |
| The markdown patcher | [`app/services/autospec/markdown_patcher.rb`](../app/services/autospec/markdown_patcher.rb) |
| The markdown renderer (Aperçu pane) | [`app/services/autospec/markdown_renderer.rb`](../app/services/autospec/markdown_renderer.rb) |
| The view tree | [`app/components/web/views/autospec_drafts/`](../app/components/web/views/autospec_drafts/) |
| The editor + attachments JS (steps 10b + 10c) | [`app/assets/static/js/autospec.js`](../app/assets/static/js/autospec.js) |
| Editor / attachments CSS (workspace grid, chips, cards, dropzone, mobile tabs) | grep `AutoSpec editor workspace` / `Attachments grid` in [`app/assets/static/css/app.css`](../app/assets/static/css/app.css) |
| Attachments controller | [`app/controllers/autospec_attachments_controller.rb`](../app/controllers/autospec_attachments_controller.rb) |
| Existing similar Phlex view (Card + Topbar + Sidebar pattern) | [`app/components/web/views/issue_show.rb`](../app/components/web/views/issue_show.rb) |
| How the `csrf_input_tag` helper works | [`app/components/web/views/base.rb`](../app/components/web/views/base.rb) |
| Where `view_kwargs` lives (the CSRF fix) | [`app/helpers/web/helpers.rb`](../app/helpers/web/helpers.rb) |
| Step-9 commit | `fd5b9c6` |
| Step-10a commit | `d2db3d6` |
| CSRF fix commit | `e4133fb` |
| Step-10b commit | `b286915` |
| Step-10c commit | `566cf41` |
| Step-11 commit  | `d4c46f3` |
| Step-12 commit  | `173c90c` |
| Briefing commit | `b0f21cd` |
| Approval recorder | [`app/services/autospec/approval_recorder.rb`](../app/services/autospec/approval_recorder.rb) |
| GitLab submitter | [`app/services/autospec/gitlab_submitter.rb`](../app/services/autospec/gitlab_submitter.rb) |
| GitLab importer | [`app/services/autospec/gitlab_importer.rb`](../app/services/autospec/gitlab_importer.rb) |
| Project briefer | [`app/services/autospec/project_briefer.rb`](../app/services/autospec/project_briefer.rb) + [`app/jobs/refresh_project_briefings_job.rb`](../app/jobs/refresh_project_briefings_job.rb) |
| Permission matrix on the model | grep `Permission matrix` in [`app/models/autospec_draft.rb`](../app/models/autospec_draft.rb) |

---

## 7. What to do FIRST in a new session

1. Read this file end-to-end (you're doing it now).
2. Skim [`autospec.md`](autospec.md) §C to confirm step status.
3. Run [§5 sanity checks](#5-fresh-session-sanity-checks) — every one.
4. **Phase D is complete.** All 4 steps (9–12) from autospec.md §C are shipped + the project briefing addon. If you're starting fresh and looking for something to do, [§3 "Deferred work"](#deferred-work--to-revisit-if-the-pilot-surfaces-a-need) lists 11 items roughly ranked by usefulness — items 1–6 are likely pilot-triggered, 7–10 are explicitly out of scope unless product priorities shift, item 11 (vocabulary tuning) is the always-applicable lever.
5. **Update this handoff if you DO start a new chantier** — keep §1, §3, §4 current so the next session has the same one-glance overview phase D enjoyed.

— Last touched 2026-06-16 after step 12 (GitLab issue import) — **phase D complete**.
