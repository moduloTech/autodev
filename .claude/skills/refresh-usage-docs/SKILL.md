---
name: refresh-usage-docs
description: Maintain the autodev user-facing and technical usage docs (docs/usage/autodev-functional-usage.md + autodev-technical-usage.md) and their screenshots. Both guides are rendered live inside the dashboard via `HelpDoc` + Redcarpet — the functional one at `/help` (open to all signed-in users), the technical one at `/admin/help` (admin-gated). Trigger when the user asks to refresh, update, regenerate, or check the usage docs, the screenshots, the user guide, the technical guide, the `/help` or `/admin/help` page, or any combination of those.
---

# Maintain the autodev usage docs

The autodev project ships two markdown guides in `docs/usage/`, both rendered live inside the dashboard:

- **`autodev-functional-usage.md`** — for non-admin, non-technical users. Describes how to confide a ticket to autodev, follow its work on the dashboard, and what each screen does. Rendered at **`/help`** (open to every signed-in user). Strictly no technical jargon: no AASM state names in code form, no route paths, no Rails/Solid Queue/Devise mentions, no code blocks, no internal architecture.
- **`autodev-technical-usage.md`** — for admins, devs, ops. Covers routes (`/admin/users`, `/admin/jobs`), `~/.autodev/config.yml`, the CLI, the AASM state machine, the polling dispatch, the error catalog, and on-disk state. Rendered at **`/admin/help`** (admin-gated via `AdminApplicationController`). Free to use jargon, code blocks, route paths, AASM state names, etc.

Both pages flow through the same pipeline:

- `app/services/help_doc.rb` — `HelpDoc.render(:functional)` / `HelpDoc.render(:technical)`. Strips the YAML frontmatter + `\newpage` markers, rewrites image refs from `screenshots/X.png` to `/help/images/X.png`, then runs the markdown through Redcarpet.
- `app/controllers/help_controller.rb` — `#show` for `/help`, plus the shared `#image` endpoint at `/help/images/:filename` (used by *both* docs — the screenshots are not sensitive).
- `app/controllers/admin/help_controller.rb` — `#show` for `/admin/help`, inherits the admin gate from `AdminApplicationController`.
- `app/components/web/views/help.rb` — generic Phlex shell: takes `content`, `active` (sidebar key), `title_key`, `subtitle_key`. Used by both pages.
- `app/assets/static/css/app.css` — `.help-doc` scope (typography, tables, image frame, blockquote).

Screenshots live under `docs/usage/screenshots/` (numbered `01-*.png` to `10-*.png`). Both docs reference the same screenshot pool. On disk the markdown still writes `screenshots/<file>.png`; the rewrite to `/help/images/<file>` happens at render time.

PDF generation is **retired** — the user previews each guide in the browser at `/help` and `/admin/help`. There is no PDF artifact to build; **never regenerate one**. The `autodev-functional-usage.pdf` / `autodev-technical-usage.pdf` files still in `docs/usage/` are dead leftovers from the old `md2pdf` flow — they no longer track the markdown, so don't update them (they can be deleted).

## When to use this skill

Trigger when the user asks for any of:

- Refresh / regenerate the usage docs or screenshots
- Sync the docs with code changes (new state, new route, new CLI flag, new screen)
- Verify nothing technical leaks into the functional doc
- Replace specific screenshots
- Add a new screen / section to either doc
- Fix something that renders wrong on the `/help` or `/admin/help` page

If a code change introduces a new user-visible state, screen, or vocabulary, propose updating the docs even when the user doesn't ask — both docs drift fast.

## Operating procedure

### 1. Diagnose what needs to change

Read both markdown files. Compare against:

- **Routes** (`autodev/config/routes.rb`) — every web route should be in `autodev-technical-usage.md` §"Routes du dashboard".
- **CLI flags** (`autodev/bin/autodev` header comment) — every flag should be in §"Outils en ligne de commande".
- **Status labels** (`autodev/config/locales/web.fr.yml`, keys `web_status_*`) — must match the FR labels in both docs (functional: pastilles d'état + vocabulary table; technical: AASM → métier mapping).
- **AASM events** (`autodev/app/models/issue.rb`) — relevant only to the technical doc.
- **Error catalog** (`autodev/CLAUDE.md` §"Error Handling") — the technical doc table should be in sync.
- **Markdown features that the rendering pipeline supports**: Redcarpet (shared between `/help` and `/admin/help`) is configured with `tables`, `fenced_code_blocks`, `autolink`, `strikethrough`, `no_intra_emphasis`, `space_after_headers`. Anything outside that (kramdown attribute lists, footnote syntax, raw HTML beyond what Redcarpet allows) will render wrong on both pages. Stick to plain GFM-style markdown.

Make a short punch list of what's stale.

### 2. Refresh screenshots (only when UI changed)

Skip screenshot refresh if only text content changed. Refresh when:

- A screen layout changed
- A new screen was added
- The captured data is too stale to make sense

There are two ways to capture. **Default to mode B (local dev server) when documenting a change that isn't deployed to prod yet** — which is the usual case, since you're shooting the screen you just changed. Use mode A (prod) only when you specifically want real production data and the screen already exists on prod.

#### Mode B — local dev server with demo data (preferred for un-shipped changes)

Runs the exact code in the working tree against an **isolated throwaway SQLite DB** seeded with non-sensitive demo rows. No prod data, no SSO/MFA round-trip, no risk of leaking real customer ticket titles into committed docs.

Two gotchas this flow handles:
- The dashboard is **SSO-gated** — `ApplicationController` has a global `before_action :authenticate_user!` (the older "no auth gate on the dashboard" note in `autodev/CLAUDE.md` is stale). Signing in via real SSO against a scratch DB won't work (zero synced memberships → the user is disabled). So we add a **temporary ENV-guarded dev-login shim** and delete it after.
- The screen only renders meaningful content if the DB has the right rows (e.g. `/errors` needs an `error` and/or `needs_clarification` issue), so we **seed** them.

Steps (paths use the session scratchpad — substitute yours):

1. **Pick scratch DB paths** and export them so every command below hits the same files:
   ```bash
   export AUTODEV_DB=$SCRATCH/autodev-shot.db AUTODEV_QUEUE_DB=$SCRATCH/autodev-shot-queue.db
   export RAILS_ENV=development
   rm -f $AUTODEV_DB $AUTODEV_QUEUE_DB        # start clean
   ```
2. **Seed demo rows + an admin user.** `config/initializers/auto_migrate.rb` builds the schema on first boot of *any* Rails process, so a `bin/rails runner` both migrates and seeds. Tailor the rows to the screen (e.g. for `/errors`: one `Issue` with `status:'error'` + a realistic `error_message`, one with `status:'needs_clarification'`; generic `project_path` like `modulotech/demo-app`, no real titles). Always seed a user so the shim has someone to log in as:
   ```bash
   mise x ruby -- bin/rails runner "User.find_or_create_by!(email:'demo@modulotech.fr'){|u| u.name='Demo'; u.admin=true; u.locale='fr'}"
   mise x ruby -- bin/rails runner /path/to/seed_<screen>.rb
   ```
   Seed issues with `Issue.create!(status: '<state>', …)` — passing `status:` directly sticks (creation isn't an AASM transition).
3. **Add the temporary dev-login shim** at `autodev/config/initializers/zzz_dev_screenshot_login.rb` — guarded so it's inert unless explicitly enabled, and **delete it in cleanup**:
   ```ruby
   if Rails.env.development? && ENV['AUTODEV_DEV_AUTOLOGIN'] == '1'
     Rails.application.config.to_prepare do
       ApplicationController.class_eval do
         skip_before_action :authenticate_user!, raise: false
         def current_user = @current_user ||= User.order(:id).first
         def user_signed_in? = current_user.present?
       end
     end
   end
   ```
4. **Boot the server** (background) with the shim enabled:
   ```bash
   AUTODEV_DEV_AUTOLOGIN=1 mise x ruby -- bin/rails server -p 4567 -b 127.0.0.1
   ```
   Poll `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4567/errors` until it returns `200` (a `302`→`/sign_in` means the shim didn't load — check `RAILS_ENV`/`AUTODEV_DEV_AUTOLOGIN`). A quick `curl … | grep` for the new wording is a good pre-flight before driving Chrome.
5. **Capture** against `http://127.0.0.1:4567` using the common Chrome steps below (the proxy step is *not* needed locally — see memory `reference-autodev-screenshot-capture`).
6. **Clean up — non-negotiable:** stop the server (`TaskStop`), `rm` the shim initializer, and `rm` the scratch DBs. Then confirm `git -C autodev status` shows only the intended doc/screenshot/locale files and **no `zzz_dev_screenshot_login.rb`**.

#### Mode A — prod dashboard (real data, already-shipped screens)

The prod dashboard is at **`https://autodev.netbird.modulotech.fr`** (see memory `reference-autodev-prod-web`), gated by SSO Microsoft 365. Reachable directly from the Docker container via HTTPS — no SSH tunnel needed for screenshots, the user just needs to be signed in via Chrome.

1. Start the Chrome DevTools proxy: invoke the **`chrome-devtools-proxy`** skill.
2. Pick the existing autodev tab (one is usually open) or `mcp__chrome-devtools__new_page` to it. Resize to **1440×900** for consistency with existing captures.
3. Verify session is active by reading the page (anything other than a redirect to `/sign_in` means OK).

#### Common Chrome steps (both modes)

1. Resize to **1440×900** for consistency with existing captures.
2. Force light theme + French via `mcp__chrome-devtools__evaluate_script`:
   ```js
   () => {
     try { localStorage.setItem('autodev-theme', 'light'); } catch(e){}
     document.documentElement.dataset.theme = 'light';
     return { theme: document.documentElement.dataset.theme, lang: document.documentElement.lang };
   }
   ```
3. Navigate to each screen and call `mcp__chrome-devtools__take_screenshot` with `fullPage: false` (viewport-only) and save under `docs/usage/screenshots/`.

Screen → file mapping (current):

| # | Screen | URL | File |
|---|---|---|---|
| 01 | Dashboard | `/` | `01-dashboard.png` |
| 02 | Issues list | `/issues` | `02-issues-list.png` |
| 03 | Errors / À surveiller (collapsed) | `/errors` | `03-errors.png` |
| 03b | Errors with technical details expanded | `/errors` + `details[0].open = true` | `03b-errors-expanded.png` |
| 04 | Projects list | `/projects` | `04-projects.png` |
| 05 | Project detail | `/projects/<slug>` | `05-project-show.png` |
| 06 | Issue detail (active) | pick an issue from `/issues?tab=active` | `06-issue-detail.png` |
| 07 | Admin users | `/admin/users` | `07-admin-users.png` |
| 08 | Sign-in (anonymous) | `/sign_in` in `isolatedContext='anon'` | `08-sign-in.png` |
| 09 | Issue detail (needs_clarification) | pick from `/issues?tab=waiting` | `09-issue-clarification.png` |
| 10 | Mission Control | `/admin/jobs` | `10-mission-control.png` |
| 11 | AutoSpec drafts list | `/autospec_drafts` | `11-autospec-list.png` |
| 12 | AutoSpec new draft form | `/autospec_drafts/new` | `12-autospec-new.png` |
| 13 | AutoSpec editor (drafting: markdown left, chat right) | a `drafting` draft from `/autospec_drafts` | `13-autospec-editor.png` |
| 14 | AutoSpec approval banner (pending_approval) | a `pending_approval` draft | `14-autospec-approval.png` |
| 15 | Project config edit form | `/projects/<slug>/edit` (admin or project collaborator) | `15-project-edit.png` |
| 16 | New project form | `/projects/new` (admin only) | `16-project-new.png` |
| 17 | Ticket templates list | `/projects/<slug>/ticket_templates` (pick a project that has templates, else it's the empty state) | `17-ticket-templates-list.png` |
| 18 | Ticket template edit form | `/projects/<slug>/ticket_templates/<id>/edit` (filled) — or `…/new` for the empty form | `18-ticket-template-form.png` |

Note on #12: select a project in the form first so the per-project **template picker** (`select[name=template_slug]`) renders — set the project `<select>` value and dispatch a `change` event. The picker only lists templates if the chosen project defines any.

For the **errors expanded** screenshot, run before the capture:
```js
() => { const d = document.querySelectorAll('details')[0]; if (d) d.open = true; }
```

For the **sign-in** screenshot, use `isolatedContext: 'anon'` so the cookie session isn't sent — otherwise you get redirected.

Don't capture `/help` or `/admin/help` themselves — they would be self-referential (the pages describe the dashboard, not themselves).

### 3. Update the markdown

For the **functional doc** (`autodev-functional-usage.md`):

- Replace stale screen descriptions matching the new screenshots.
- Keep the strict no-jargon rule. Use `grep -inE "(AASM|/issues|/errors|Rails|SQLite|Solid Queue|Devise|OmniAuth|CSRF|Puma|Server-Sent|status pill|danger-claude|mr-review|webhook|YAML)" docs/usage/autodev-functional-usage.md` to catch leaks after editing. Only `URL` mentions tied to the visible GitLab URL of a project are acceptable.
- The vocabulary tables ("pastilles d'état" and the high-level workflow) must use the exact FR labels from `web.fr.yml`. No code-form state names.
- Stay within GFM markdown: headings, lists, tables, bold/italic, inline code, fenced code, links, images. Anything fancier (kramdown attribute lists, footnotes, raw HTML beyond basic) will render wrong on `/help`.

For the **technical doc** (`autodev-technical-usage.md`):

- Keep the routes table, CLI table, AASM mapping table, polling pass list, pipeline matrix, error catalog, and on-disk-state table in lockstep with the code.
- AASM event names are written in `code form` here (e.g. `pipeline_failed_code!`). Status labels appear in **both** technical and métier form (the mapping table is the canonical lookup).
- Stay within the same GFM subset as the functional doc — the technical doc flows through the same Redcarpet pipeline (`HelpDoc.render(:technical)`) and is rendered at `/admin/help`. Tables, fenced code, autolinking, strikethrough, inline code are all fine; kramdown attribute lists, footnotes, raw HTML beyond basic are not.

### 4. The YAML frontmatter and `\newpage` markers

Both files still carry the YAML frontmatter (`--- title: … ---`) and the LaTeX-style `\newpage` separators, vestigial from the retired PDF flow. **Do not strip them when editing** — but not because a PDF might come back (it won't). They stay for two live reasons: `HelpDoc#strip_pandoc_only` removes both before passing each source to Redcarpet, so they're invisible on `/help` and `/admin/help`; and on GitHub the frontmatter renders as a small grey table at the top (harmless). Removing them would only churn the markdown for no gain.

Bump the `date:` field to today's absolute date whenever you touch the file — it's the guide's "last updated" stamp (shown on GitHub), unrelated to the dead PDF flow.

### 5. Verify the rendered help pages

After editing either guide, sanity-check the corresponding rendered page:

- If the user has a local dev server running, browse to `http://localhost:4567/help` (functional) or `http://localhost:4567/admin/help` (technical, requires `current_user.admin?`). Both pages render with the standard sidebar + topbar and the article body in the `.help-doc` CSS scope (see `app/assets/static/css/app.css`).
- If no local server is up, you can render either headlessly with `mise x ruby -- bin/rails runner 'puts HelpDoc.render(:functional)'` (or `:technical`) and grep for obvious issues (unrendered `\newpage`, leftover frontmatter, dangling markdown syntax).
- Confirm image refs were rewritten: `HelpDoc.render(:functional).scan(%r{/help/images/[\w\-.]+}).size` should equal the count of `![…](screenshots/…)` in the source (likewise for `:technical`).

### 6. Update the CHANGELOG

Per the project's [workflow rules](../../../CLAUDE.md): when modifying anything in the project, add an entry under `## [Unreleased]` in `autodev/CHANGELOG.md` describing the doc change. Use `### Changed` (or `### Added` for a new screen / section).

### 7. Don't commit unless asked

Stop after editing. The user previews the rendered guides on `/help` and `/admin/help` in their browser before deciding to commit.

## Quick references

- **Memory pointers**:
  - `reference-autodev-prod-web` — prod URL + SSO
  - `reference-autodev-prod-db` — SSH/DB access (only if you need to inspect data while picking issues for screenshots)
- **CLAUDE.md sections to consult**:
  - "Configuration" — `app:` block layout
  - "Web UI" — routes
  - "State Machine (AASM)" — state list + transitions
  - "Error Handling" — error catalog
- **Rendering pipeline (shared by both docs)**:
  - `app/services/help_doc.rb` — `HelpDoc.render(:functional | :technical)`, strip + image rewrite + Redcarpet
  - `app/controllers/help_controller.rb` — `#show` for `/help` + shared `#image` endpoint at `/help/images/*`
  - `app/controllers/admin/help_controller.rb` — `#show` for `/admin/help`, inherits admin gate from `AdminApplicationController`
  - `app/components/web/views/help.rb` — generic Phlex shell, parameterized by `active` / `title_key` / `subtitle_key`
  - `app/assets/static/css/app.css` — `.help-doc` typography block
