# The activity note links the dashboard (Autodev #124)

## Problem

Autodev keeps one activity note per GitLab issue (`lib/autodev/activity_logger.rb`),
rewritten at every step. Nothing in it points at the issue's page on the
dashboard (`GET /issues/:id`, `config/routes.rb:44`), so a reader on GitLab who
wants the full journal, the state or the error has to find the row by hand.

## Measurements

- Production, 08/10/2026: 135 of 148 `issues` rows carry an `activity_note_id`.
- The note of powerpanne/core#16074 (note 858533, written by alpha-54) reads
  `":robot: **autodev** (v1.0.0.alpha.54) — Journal d'activite\n\n- \`09-22 16:56\` — …"`,
  94 lines, `\n` line endings: line 0 is the header, line 1 is blank, every
  later line is an entry. Entries carry no version tag; only the header does.
- `upsert` never rewrites the header: it reads the body back and appends to it
  (`"#{note.body}\n#{entry}"`) or moves the matching line (`replace_or_append`).
  `enforce_size_cap` keeps `lines.first(2)` and drops the oldest entries.

## Decisions

1. **Config key `dashboard_url`**, global, `Config::DEFAULTS['dashboard_url'] = nil`
   (owner). Unset → the note is posted without a link and nothing fails. When
   set, `ConfigValidator` refuses at boot anything that is not an `http`/`https`
   URL with a host and no credentials, query or fragment (credentials would be
   published on every note; a query or fragment swallows `/issues/<id>`, a parenthesis closes the Markdown link) —
   including a present-and-blank string (a bare `dashboard_url:` key loads as nil, i.e. unset), the repository's rule
   for optional strings (`mr_review_token`, `OPTIONAL_STRING_FIELDS`): a blank
   would read as "unset" while looking configured, and a malformed one would put
   a broken link on every note of every ticket.
2. **The link targets `/issues/<row id>`**, the autodev primary key, not the
   GitLab iid (owner). `Config.dashboard_issue_url(config, issue_id)` is the one
   place base and path are joined: trailing slashes are stripped from the base
   before `/issues/<id>` is appended, so the owner's value
   `https://autodev.netbird.modulotech.fr/` yields
   `https://autodev.netbird.modulotech.fr/issues/160` and never `//issues`. A
   base with a path prefix (a reverse proxy mounting autodev under `/autodev/`)
   keeps it.
3. **The link lives in the header line (line 0)**, appended after the existing
   header text: `":robot: **autodev** (v…) — Journal d'activite · [Fiche du ticket dans Autodev](url) (acces Autodev requis)"`.
   Line 0 is the one line every writer already preserves — `enforce_size_cap`
   keeps the first two lines, `replace_or_append` matches entries only (the
   header begins with `:robot:`, no entry pattern matches it). A separate line
   would either be a third "header" line the truncation drops, or require
   widening the truncation.
4. **The header is regenerated on every update.** `upsert` replaces line 0 with
   a freshly built header before appending or replacing an entry, which is how
   the 135 existing notes receive the link at their next update (owner), and
   how a link follows a later change of `dashboard_url` (set, changed, or
   removed). The rewrite is guarded: line 0 is replaced only when it starts with
   `ActivityLogger::HEADER_PREFIX` (`:robot: **autodev**`, which both locales'
   `activity_header` start with — a test derives that from the two tables), so
   a note whose first line is not autodev's header is never overwritten. The
   upsert makes no extra GitLab call: it already reads and edits the note.
5. **The label says Autodev access is required** (localized fr + en,
   `activity_dashboard_link`, ASCII like every string posted on GitLab): the
   page sits behind `authenticate_user!`, so a GitLab user without an Autodev
   account lands on `/sign_in`, and a signed-in user who is not a member of
   the project gets a 404 (`issues_dataset` scopes to `visible_project_paths`).
   "Access" covers both; "sign-in" alone would be untrue for the second (owner:
   accepted, label at our discretion; wording changed after the domain review).

## Assumptions

- Regenerating line 0 also refreshes its version tag, which then names the
  version that last wrote the note rather than the one that created it. The tag
  carries no other meaning (entries have none; nothing parses it).
- `Web.config` is the config the workers read (`config/initializers/load_autodev_config.rb`
  populates it in every Rails process, the Solid Queue worker included), as for
  `HealthReport`, `UsageGate` and the probes. Where it is nil (a test, a bare
  script), the note is posted without a link.

## Out of scope

- Any other GitLab comment (notifications, MR notes): the ticket names the
  activity note.
- Writing `dashboard_url` in production: the owner sets it after deploy.
