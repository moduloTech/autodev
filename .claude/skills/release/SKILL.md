---
name: release
description: Release a new version of autodev. Handles changelog, commit, tag, GitHub release, and Homebrew formula update. Trigger when the user asks to release, publish, or ship a new version.
---

# Release Autodev

Run the full release pipeline for autodev. The user provides the version number (e.g. `0.0.3`). If no version is provided, suggest a coherent number by reading the CHANGELOG.

## Conventions

- `<version>`: the version number without `v` prefix
- `<Claude model name and version>`: the name and version of the current Claude model (e.g. `Opus 4.8`)
- The GitHub repo name is `modulotech/autodev`.
- The Homebrew formula is at `/opt/homebrew/Library/Taps/modulotech/homebrew-tap/Formula/autodev.rb`

## Steps

### 1. Analyze changes

- `cd` into the tool's subdirectory.
- Run `git diff` to review all uncommitted changes.
- If there are no changes, abort — there is nothing to release.

### 2. Update version constant

- Find the `VERSION` constant in the tool's source code (e.g. `VERSION = "0.1.2"` in the bin script or `Autodev::VERSION` in `lib/autodev.rb`).
- Update it to `<version>`.

### 3. Update CHANGELOG.md

- Add a new section under `## [Unreleased]` with the version and today's date.
- Categorize changes under `### Added`, `### Changed`, `### Fixed`, or `### Removed` as appropriate.
- Write concise, user-facing descriptions of what changed.

### 4. Refresh usage docs

- Follow the `refresh-usage-docs` skill to sync `docs/usage/autodev-functional-usage.md` + `autodev-technical-usage.md` (and screenshots when the UI changed) with the changes being released. Read that skill for the full procedure — don't reimplement it here.
- The skill normally stops before committing; in the release flow, let its doc/screenshot edits flow into this release's commit (next step) instead.

### 5. Commit and tag

- Stage only `CHANGELOG.md`, the changed source files, and any usage-doc/screenshot files touched in step 4 (not unrelated files).
- Commit with message:
  ```
  Release v<version>

  <short description of changes>

  Co-Authored-By: Claude <Claude model name and version> <noreply@anthropic.com>
  ```
- Tag as `v<version>`.

### 6. Push

- `git push && git push origin v<version>`
- If the push fails with `Host key verification failed`, seed the `known_hosts` file and retry:
  ```bash
  mkdir -p ~/.ssh && ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts
  ```

### 7. Create GitHub release

- Use `gh release create v<version> --title "v<version>" --notes "<notes>"`.
- Notes should mirror the CHANGELOG section for this version (markdown formatted).

### 8. Update Homebrew formula

- Download the tarball and compute sha256:
  ```bash
  curl -sL "https://github.com/moduloTech/<tool>/archive/refs/tags/v<version>.tar.gz" | shasum -a 256
  ```
- Update `url`, `sha256`, **and `version`** in `/opt/homebrew/Library/Taps/modulotech/homebrew-tap/Formula/<tool>.rb`. The formula pins an explicit `version "<version>"` line separate from the tag in `url` — if you bump `url`/`sha256` but leave `version` stale, `brew upgrade` reads the old `version`, sees no change, and reports "already installed" without upgrading. Verify all three lines afterwards: `grep -E 'url |version |sha256 ' Formula/<tool>.rb`.
- Commit in the tap repo with message:
  ```
  Update <tool> to v<version>

  Co-Authored-By: Claude <Claude model name and version> <noreply@anthropic.com>
  ```
- Push the tap: `cd /opt/homebrew/Library/Taps/modulotech/homebrew-tap && git push`

### 9. Confirm

- Print the GitHub release URL.

