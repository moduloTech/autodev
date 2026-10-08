# Plan — the activity note links the dashboard (Autodev #124)

Spec: `docs/superpowers/specs/2026-10-08-the-activity-note-links-the-dashboard-design.md`.
One lane (four production files, two locale files): no parallel dispatch.

## Contract

- `Config::DEFAULTS['dashboard_url'] = nil`.
- `Config.dashboard_issue_url(config, issue_id) -> String | nil` — nil when
  `config` is not a Hash, the value is nil / not a String / blank, or
  `issue_id` is nil; else `"#{base.sub(%r{/+\z}, '')}/issues/#{issue_id}"`.
- `ConfigValidator.validate_dashboard_url!(config)` (private, called from
  `validate_globals!`): nil passes; anything else must be a String that
  `URI.parse` reads as `URI::HTTP` (http or https) with a non-empty host, else
  `ConfigError` naming the key and the value.
- `ActivityLogger::HEADER_PREFIX = ':robot: **autodev**'`.
- `ActivityLogger.header_line(issue)` (private) — `activity_header`, plus
  `" · " + activity_dashboard_link(url:)` when `Config.dashboard_issue_url`
  answers a URL for `Web.config` and `issue.id`.
- `create` uses `header_line`; `upsert` replaces `lines[0]` with `header_line`
  when it starts with `HEADER_PREFIX`, before append/replace/size cap.
- Locale key `activity_dashboard_link` in `activity.fr.yml` / `activity.en.yml`,
  placeholder `%{url}`.
- `Config::TEMPLATE` documents the key (commented), with the owner's value.

## Steps (TDD)

1. `test/config_dashboard_url_test.rb`: join without `//` (one and several
   trailing slashes, none, path prefix), nil / blank / non-String → nil, nil
   issue id → nil; validator accepts nil, http, https; refuses blank, `ftp://`,
   no scheme (`autodev.local`), no host (`https://`), non-String (Integer).
   `Config.load` default is nil.
2. `test/activity_logger_dashboard_link_test.rb`: created note's line 0
   carries the link to `/issues/<row id>` (not the iid) when set; no link and
   no error when unset (Web.config nil, key nil); upsert of a legacy body
   (alpha-54 header, no link) rewrites line 0 with the link and keeps every
   entry; upsert with `replace_pattern` keeps the link; size cap keeps the
   link; a body whose line 0 is not autodev's header is left as is; a changed
   `dashboard_url` replaces the old link (one link, never two); both locales'
   `activity_header` start with `HEADER_PREFIX`; en locale label is English.
3. Implement; full suite; rubocop; CHANGELOG; CLAUDE.md + technical guide.
