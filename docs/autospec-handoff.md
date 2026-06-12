# AutoSpec — Handoff

**Last updated:** 2026-06-12 (after step 10a + CSRF fix at SHA `e4133fb`)
**Canonical plan:** [`autospec.md`](autospec.md) §C (12-step attack order, marked ⬜/✅)
**Latest release tag:** `v1.0.0-alpha.17` (phase D not yet released — 4 commits ahead of master)

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
| **10b** | Markdown editor (toggle Édition/Aperçu, ⌘+B/I/K, autosave) + meta-chip editing + title editing + two-column desktop layout | ⬜ next |
| **10c** | Drag-drop attachments via ActiveStorage + AttachmentCard grid + mobile responsive (tabs) + dark-mode polish | ⬜ |
| **11** | Workflow approbation: owners' encart, vote orchestration, GitLab issue creation pipeline | ⬜ |
| **12** | Import an existing GitLab issue as a draft (lowest priority — §A "very nice to have") | ⬜ |

The sub-slice names (9a/9b/9c) are historical — they all live in one
commit now. Use them in commit messages or PR titles only if you want
to be precise about WHICH part of step 9 you're touching.

---

## 1. State at this commit

```
e4133fb fix(web): emit CSRF token on Phlex forms — form_authenticity_token is private
d2db3d6 feat(autospec): frontend backbone (step 10a) + CTA wire-ups
fd5b9c6 feat(autospec): backend (step 9) — schema, models, chat service, suggestion applier
4da1007 docs(autospec): refresh plan after railsification + users-rollout
da2ce03 Release v1.0.0-alpha.17   ← latest tag, master HEAD before phase D
```

Not pushed to origin. Branch is 4 commits ahead. No release tag yet.

Mapping to [`autospec.md`](autospec.md) §C:

| Step | Title | Status |
|---|---|---|
| **9** | Backend AutoSpec | ✅ done (`fd5b9c6`) |
| **10** | Frontend AutoSpec | 🟡 backbone done (10a `d2db3d6`); editor + attachments + responsive layout remain |
| **11** | Workflow approbation | ⬜ open |
| **12** | Import GitLab d'un ticket existant | ⬜ open |

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

### HTTP layer

| Route | Action | Notes |
|---|---|---|
| `GET /autospec_drafts` | `#index` | Lists `current_user.autospec_drafts` |
| `GET /autospec_drafts/new` | `#new` | Form scoped to `current_user.visible_projects` |
| `POST /autospec_drafts` | `#create` | Rejects project_id outside visibility |
| `GET /autospec_drafts/:id` | `#show` | Single-column layout |
| `POST /autospec_drafts/:id/chat` | `#chat` | `respond_to`: HTML redirect / JSON |
| `POST /autospec_drafts/:id/apply_suggestion` | `#apply_suggestion` | `respond_to`: HTML redirect / JSON (409 on re-apply, 404 if tool_use_id absent) |

Mounted via `resources :autospec_drafts, only: %i[index new create show]`
+ two `:member` POSTs. Author-only auth check (`@draft.user_id ==
current_user.id`). Wider owner/contributor matrix (autospec.md §J) is
step 11.

Token-level SSE deferred per autospec.md §L — `#chat` is synchronous
JSON. Rebinding to `ActionController::Live` + the SDK's
`messages.stream(…)` is ~30 LOC when step 10b/10c proves the
typing-effect UX is worth it.

### View layer (`app/components/web/views/autospec_drafts/`)

- `Index` — list of drafts, empty state, "Nouveau brouillon" CTA
- `New` — project picker + title + initial markdown
- `Show` — meta card (status/iteration/destination/project) +
  read-only markdown card + conversation card (messages + composer +
  apply buttons per tool_call, disabled when `applied_at` set)

All three extend `Web::Views::Base` and reuse `Components::{Card,
Sidebar, Topbar}`. The `csrf_input_tag` helper on Base emits the
hidden authenticity_token input — see §4 for the fix story.

### Test surface

| Area | File(s) | Count |
|---|---|---|
| Models | `test/models/autospec_*.rb` (5 files) | 32 |
| Services | `test/services/autospec/*.rb` (6 files) | 48 |
| Controllers (JSON) | `test/controllers/autospec_drafts_controller_test.rb` | 10 |
| Controllers (HTML) | `test/controllers/autospec_drafts_html_test.rb` | 11 |
| **Total added at phase D** | | **101** |

Suite total at HEAD: **638 runs, 1172 assertions, 0 failures**.

---

## 3. Pattern for the next slices

### Step 10b — markdown editor + meta chips + title editing + two-col layout

**What's missing** on the Show page (cf. `design/spec_update/README.md` §2-6):

- Toolbar with **Édition | Aperçu** segmented tabs (sticky top of editor column)
- FormatToolbar (B / I / `</>` / H / list / quote / 📎 / 🖼️) when in Édition
- Markdown textarea (mono 13.5px, min-height 320px, resize vertical)
- Markdown preview render when in Aperçu (Redcarpet is already vendored — see `app/services/help_doc.rb` for the GFM pipeline)
- Title input editable in place (28px / 600)
- Meta chips clickable → open menu to edit (Type, Priorité, Assigné, Tags)
- Keyboard shortcuts: `⌘+B` / `⌘+I` / `⌘+K` (link) / `⌘+Enter` (submit "Créer le ticket")
- Autosave to a new endpoint every 2s + localStorage backup keyed `autodev:draft:<id>`
- Two-column desktop layout: editor centre `max-width: 820px`, chat right `0 0 380px`

**Where to add code:**

- View: extend `Web::Views::AutospecDrafts::Show` — replace `render_markdown_card` with the editor; the conversation card moves to a right column.
- Controller: add `#update` action with PATCH `/autospec_drafts/:id` carrying `title`, `markdown`, `meta_chips`. Extend `resources :autospec_drafts` with `:update`.
- JS: Layout's `APP_JS` is the obvious place for now (mirrors the SSE+heartbeat code from alpha.16). For step 10b's complexity, consider extracting an `autospec.js` served via `AssetsController`.

**Reference patterns:**

- For the toggle Édition/Aperçu UI, look at `Web::Views::Issues` tabs (`render_tab` / `tab_style`) — same pill-style segmented tabs.
- For Redcarpet rendering with auto-link + GFM, copy from `HelpDoc.render` (sanitisation already wired).
- For inline-edit forms posting via JS, look at the existing dashboard refresh pattern; nothing fancier than `fetch` + replace HTML chunk.

### Step 10c — drag-drop attachments + responsive

**Already wired** in step 9:

- `AutospecAttachment` model with `has_one_attached :file`
- ActiveStorage `:local` service under `<Rails.root>/storage/`
- Test env uses `:test` service rooted at `tmp/storage/` (10b/10c tests don't need new infra)

**What's missing:**

- Dropzone overlay on the editor column (cf. README.md §7)
- `POST /autospec_drafts/:id/autospec_attachments` endpoint (multipart) creating an `AutospecAttachment` + attaching the file
- AttachmentCard grid below the markdown editor (autospec.md §F — 220px columns, ✕ button per card, footer with filename + dims + copy-markdown button)
- At submission time (step 11's GitLab pipeline): download each blob, upload via GitLab's `/projects/:id/uploads`, rewrite the markdown to point at GitLab URLs (cf. autospec.md §F "Flux à deux temps")
- Mobile: tabs **Édition | Discussion** under the topbar (≤960px breakpoint)
- Dark-mode token polish (existing tokens.css already supports dark, just verify the new components)

### Step 11 — workflow approbation

**AASM is already mounted** on `AutospecDraft` with 5 events. What's missing:

- `Autospec::ApprovalRecorder` service: creates an `AutospecApproval` row, checks quorum at `current_iteration`, fires `finalize!` when all owners voted approved OR `mark_rejected!` on first rejection.
- Dashboard widget on `/` for owners: list of drafts in `pending_approval` where the owner hasn't voted yet (matrix in autospec.md §J).
- `Autospec::GitlabSubmitter` service called from `finalize!`'s after-transition hook:
  - `POST /api/v4/projects/:id/issues` with the draft markdown
  - Upload each attachment via `POST /api/v4/projects/:id/uploads`
  - Rewrite markdown to point at GitLab upload URLs
  - Add `labels_todo` if `destination == 'autodev'`
  - Stamp `gitlab_issue_iid` + `gitlab_issue_url` + `submitted_at` on the draft
- Owner-only routes: `POST /autospec_drafts/:id/approve` and `POST /autospec_drafts/:id/reject` (with reason).
- Auth: extend the `authorize_author!` controller filter to a finer matrix — author can edit + retract, owners can vote, admin sees all.

Reference: autospec.md §E (lifecycle diagram), §F (attachment upload at submission), §J (rôles matrix).

### Step 12 — GitLab import

Lowest priority. A service that takes a GitLab issue URL, fetches the
body via the `gitlab` gem (already in `Gemfile`), and creates an
`AutospecDraft` pre-populated with the title + markdown. Useful for
backfilling drafts from existing issues during the pilot.

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
# expect 638+ runs, 0 failures, 0 errors

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
| The view tree | [`app/components/web/views/autospec_drafts/`](../app/components/web/views/autospec_drafts/) |
| Existing similar Phlex view (Card + Topbar + Sidebar pattern) | [`app/components/web/views/issue_show.rb`](../app/components/web/views/issue_show.rb) |
| How the `csrf_input_tag` helper works | [`app/components/web/views/base.rb`](../app/components/web/views/base.rb) |
| Where `view_kwargs` lives (the CSRF fix) | [`app/helpers/web/helpers.rb`](../app/helpers/web/helpers.rb) |
| Step-9 commit | `fd5b9c6` |
| Step-10a commit | `d2db3d6` |
| CSRF fix commit | `e4133fb` |

---

## 7. What to do FIRST in a new session

1. Read this file end-to-end (you're doing it now).
2. Skim [`autospec.md`](autospec.md) §C to confirm step status.
3. Run [§5 sanity checks](#5-fresh-session-sanity-checks) — every one.
4. Pick the next step from [§3](#3-pattern-for-the-next-slices). Default: 10b (markdown editor — biggest UX gap).
5. **Update this handoff at the end of the session** — §1 (state at this commit), §3 (mark the step done, append gotchas if any), §4 (any new traps). Future-you (or the next agent) will thank you.

— Last touched 2026-06-12 after step 10a + CSRF fix.
