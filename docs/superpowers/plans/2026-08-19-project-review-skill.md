# Project Review Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the review step run the reviewed project's own review skill when the project declares one, with autodev posting the findings itself.

**Architecture:** A new per-project `review_skill` setting selects a skill from the cloned repo's `.claude/skills/`. The review step clones the MR branch, runs `danger-claude` there with a prompt that names that one skill and forbids any GitLab write, and reads the consolidated findings back from a JSON file outside the clone. Autodev then posts them: anchorable blocking-class findings as inline discussions, everything else as one summary comment. No `review_skill` → today's `mr-review` binary, untouched.

**Tech Stack:** Ruby 3.2+, Rails 8.1, `gitlab` gem 5.1, AASM, minitest, `danger-claude` CLI.

**Spec:** `docs/superpowers/specs/2026-08-19-project-review-skill-design.md`

## Global Constraints

- TDD: a failing test first, every task.
- `bundle exec rake test` green, and **every test file must also pass run on its own** (`bundle exec ruby -Itest test/<f>_test.rb`) — Autodev #64. Never add a `require 'autodev/…'` to `test/rails_helper.rb`.
- `mise x ruby -- rubocop` must land on the pre-existing **46**-offence baseline. Never edit `.rubocop.yml`. No new `rubocop:disable` without a written reason.
- `CHANGELOG.md` `[Unreleased]` updated in the same commit, in English.
- Conventional Commits, referencing `(Autodev #74)`.
- Every user-facing string goes through `Locales.t` and exists in `fr` **and** `en`. The derived-key guard `test/i18n_derived_keys_test.rb` (Autodev #68) must stay green.
- Code and comments in English.
- A GitLab read that can fail goes through `GitlabHelpers.answer` (Autodev #62/#67); the guard `test/api_failure_is_not_a_verdict_test.rb` must stay green.

---

### Task 1: The `review_skill` per-project setting

**Files:**
- Create: `db/migrate/20260819000001_add_review_skill_to_projects.rb`
- Modify: `app/models/project.rb` (`OPTIONAL_LABEL_FIELDS` → generalised, `SCALAR_CONFIG_KEYS`)
- Modify: `lib/autodev/config.rb:122` (`DB_BACKED_PROJECT_FIELDS`)
- Modify: `lib/autodev/config_validator.rb` (`OPTIONAL_LABEL_FIELDS` → `OPTIONAL_STRING_FIELDS`)
- Modify: `lib/autodev/project_validator.rb:108` (`validate_optional_label_types!` → `validate_optional_string_fields!`)
- Modify: `app/services/yaml_project_importer.rb:55` (`CONFIG_KEYS`)
- Modify: `app/components/web/views/project_edit.rb` (field in the "basic" section)
- Modify: `config/locales/web.fr.yml`, `config/locales/web.en.yml`
- Test: `test/models/project_review_skill_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Project#to_project_config` emits `'review_skill' => String` when the column is set and omits the key when nil. `@project_config['review_skill']` is how every later task reads it.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/project_review_skill_test.rb
# frozen_string_literal: true

require_relative '../rails_helper'

# `review_skill` names the skill the review step loads from the cloned repo
# (Autodev #74). Optional: absent means the mr-review binary, which is the right
# answer for a project that ships no review skill.
class ProjectReviewSkillTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup = setup_database

  def project(**attrs)
    Project.new({ gitlab_path: 'group/app', labels_todo: ['To do'],
                  label_doing: 'Doing', label_done: 'Done' }.merge(attrs))
  end

  def test_a_project_without_a_review_skill_is_valid
    assert_predicate project, :valid?
  end

  def test_a_declared_review_skill_reaches_the_project_config
    config = project(review_skill: 'prepare-mr').to_project_config
    assert_equal 'prepare-mr', config['review_skill']
  end

  def test_an_unset_review_skill_is_absent_from_the_project_config
    refute project.to_project_config.key?('review_skill')
  end

  def test_a_blank_review_skill_is_rejected_rather_than_read_as_unset
    subject = project(review_skill: '')
    refute_predicate subject, :valid?
    assert_includes subject.errors.attribute_names, :review_skill
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/models/project_review_skill_test.rb`
Expected: FAIL — `unknown attribute 'review_skill'`.

- [ ] **Step 3: Add the migration**

```ruby
# db/migrate/20260819000001_add_review_skill_to_projects.rb
# frozen_string_literal: true

# The skill the review step loads from the cloned repo (Autodev #74).
#
# Nullable and optional. The name differs per project — `mr-review` is the
# author-side skill on powerpanne/core, while on ff/fast/core the author-side one
# is `prepare-mr` and `mr-review` is the *reviewer* skill, which would be the
# wrong role. That is why this is declared rather than discovered by convention.
# Unset means the `mr-review` binary, which stays the right answer where no
# project skill exists.
class AddReviewSkillToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :review_skill, :string, if_not_exists: true
  end
end
```

- [ ] **Step 4: Generalise the optional-string validation and register the field**

In `app/models/project.rb`, replace the label-specific constant with one that says what it means, and add the key:

```ruby
  # "If set, must not be blank" — a present-and-blank value is a typo, and it
  # would otherwise read as "not configured" and silently take the fallback.
  # `label_attention` (Autodev #63) then `review_skill` (Autodev #74).
  OPTIONAL_STRING_FIELDS = %i[label_attention review_skill].freeze
```

Update the `validates(*OPTIONAL_LABEL_FIELDS, presence: true, allow_nil: true)` line to use `OPTIONAL_STRING_FIELDS`, and add `review_skill` to `SCALAR_CONFIG_KEYS`.

Then add `review_skill` to `Config::DB_BACKED_PROJECT_FIELDS`, to `YamlProjectImporter::CONFIG_KEYS`, and rename `ConfigValidator::OPTIONAL_LABEL_FIELDS` to `OPTIONAL_STRING_FIELDS` with `review_skill` added, adjusting `ProjectValidator.validate_optional_label_types!` to `validate_optional_string_fields!` (same body, new name, both call sites updated).

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec ruby -Itest test/models/project_review_skill_test.rb`
Expected: PASS, 4 runs.

- [ ] **Step 6: Add the dashboard field and its i18n**

In `app/components/web/views/project_edit.rb`, add `review_skill` beside `label_attention` in the basic section. In both `config/locales/web.fr.yml` and `web.en.yml`, add:

```yaml
  web_project_edit_desc_review_skill: "Skill de revue du projet, chargé depuis .claude/skills/ du dépôt (ex. mr-review, prepare-mr). Vide : le binaire mr-review est utilisé."
```

(and the English wording in `web.en.yml`).

- [ ] **Step 7: Run the full suite, RuboCop, and the isolated files**

Run: `bundle exec rake test` — expected 0 failures.
Run: `bundle exec ruby -Itest test/i18n_derived_keys_test.rb` — expected PASS (the new key is covered by a declared family).
Run: `mise x ruby -- rubocop` — expected 46 offences.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: a project can declare the review skill the review step loads (Autodev #74)"
```

---

### Task 2: `ReviewContract` — parse the findings and classify them

**Files:**
- Create: `lib/autodev/review_contract.rb`
- Modify: `lib/autodev.rb` (add the `require_relative`)
- Test: `test/review_contract_test.rb`

**Interfaces:**
- Consumes: `Project#to_project_config` from Task 1 (not directly — this task is pure).
- Produces: `ReviewContract.parse(json_string)` → a `ReviewContract` responding to `#verdict` (String), `#summary` (String), `#inline` (Array of `{file:, line:, severity:, body:}`), `#summary_only` (Array of the same shape without `file`/`line` guaranteed). Raises `ReviewContract::InvalidError` (a subclass of `AutodevError`) on anything unparseable or off-schema.

- [ ] **Step 1: Write the failing test**

```ruby
# test/review_contract_test.rb
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/review_contract'

# The contract the project's review skill writes, and the single rule that
# decides what becomes an inline discussion (Autodev #74): a finding is inline
# when it is BOTH anchorable (carries file + line) AND blocking-class
# (severity error or warning). One rule, so the two conditions cannot be applied
# in the wrong order.
class ReviewContractTest < Minitest::Test
  def contract(findings, verdict: 'changes_requested')
    ReviewContract.parse({ verdict: verdict, summary: 'S', findings: findings }.to_json)
  end

  def test_an_anchorable_blocking_finding_is_inline
    c = contract([{ file: 'a.rb', line: 4, severity: 'error', body: 'B' }])
    assert_equal 1, c.inline.size
    assert_empty c.summary_only
  end

  def test_an_anchorable_nitpick_is_not_inline
    c = contract([{ file: 'a.rb', line: 4, severity: 'nitpick', body: 'B' }])
    assert_empty c.inline
    assert_equal 1, c.summary_only.size
  end

  def test_a_blocking_finding_without_a_line_is_not_inline
    c = contract([{ severity: 'error', body: 'B' }])
    assert_empty c.inline
    assert_equal 1, c.summary_only.size
  end

  def test_a_clean_review_parses_and_yields_nothing_to_post
    c = contract([], verdict: 'approve')
    assert_equal 'approve', c.verdict
    assert_empty c.inline
    assert_empty c.summary_only
  end

  def test_unparseable_json_raises
    assert_raises(ReviewContract::InvalidError) { ReviewContract.parse('not json') }
  end

  def test_a_missing_verdict_raises
    assert_raises(ReviewContract::InvalidError) { ReviewContract.parse({ findings: [] }.to_json) }
  end

  def test_an_unknown_verdict_raises
    assert_raises(ReviewContract::InvalidError) do
      ReviewContract.parse({ verdict: 'lgtm', summary: '', findings: [] }.to_json)
    end
  end

  def test_an_unknown_severity_raises
    assert_raises(ReviewContract::InvalidError) do
      contract([{ file: 'a.rb', line: 1, severity: 'blocker', body: 'B' }])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/review_contract_test.rb`
Expected: FAIL — `cannot load such file -- autodev/review_contract`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/autodev/review_contract.rb
# frozen_string_literal: true

require 'json'

# What the project's review skill hands back (Autodev #74).
#
# A file rather than stdout: `capture_session_and_text` already parses stdout for
# the session id, a skill's prose legitimately contains fenced code blocks, and a
# truncated stdout would read as an empty review — that is, as a clean MR. That is
# the failure family Autodev #62 exists to remove. A missing or off-schema file is
# an unambiguous failure instead.
class ReviewContract
  class InvalidError < AutodevError; end

  VERDICTS = %w[approve changes_requested].freeze
  SEVERITIES = %w[error warning info nitpick].freeze
  # What both project skills call blocking-class.
  BLOCKING = %w[error warning].freeze

  attr_reader :verdict, :summary, :inline, :summary_only

  def self.parse(raw)
    data = JSON.parse(raw.to_s)
    raise InvalidError, 'contract is not a JSON object' unless data.is_a?(Hash)

    new(data)
  rescue JSON::ParserError => e
    raise InvalidError, "contract is not valid JSON: #{e.message}"
  end

  def initialize(data)
    @verdict = data['verdict']
    raise InvalidError, "verdict must be one of #{VERDICTS.join(', ')}" unless VERDICTS.include?(@verdict)

    @summary = data['summary'].to_s
    findings = data['findings'] || []
    raise InvalidError, 'findings must be an array' unless findings.is_a?(Array)

    validate_severities!(findings)
    @inline, @summary_only = findings.partition { |f| inline?(f) }
  end

  private

  # The one rule: anchorable AND blocking-class.
  def inline?(finding)
    BLOCKING.include?(finding['severity']) &&
      !finding['file'].to_s.strip.empty? &&
      finding['line'].to_s.match?(/\A\d+\z/)
  end

  def validate_severities!(findings)
    findings.each do |f|
      raise InvalidError, 'each finding must be an object' unless f.is_a?(Hash)
      raise InvalidError, "unknown severity #{f['severity'].inspect}" unless SEVERITIES.include?(f['severity'])
    end
  end
end
```

Add `require_relative 'autodev/review_contract'` to `lib/autodev.rb`, after the errors requires.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Itest test/review_contract_test.rb`
Expected: PASS, 8 runs.

- [ ] **Step 5: Run the full suite and RuboCop**

Run: `bundle exec rake test` and `mise x ruby -- rubocop` — expected 0 failures, 46 offences.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: one rule decides what a review finding becomes (Autodev #74)"
```

---

### Task 3: `ReviewPublisher` — post the findings with autodev's own PAT

**Files:**
- Create: `lib/autodev/review_publisher.rb`
- Modify: `lib/autodev.rb`
- Modify: `config/locales/notifications.fr.yml`, `config/locales/notifications.en.yml`
- Test: `test/review_publisher_test.rb`

**Interfaces:**
- Consumes: `ReviewContract` from Task 2 (`#inline`, `#summary_only`, `#summary`, `#verdict`).
- Produces: `ReviewPublisher.new(client:, project_path:, logger:, locale:).publish(mr_iid:, contract:)` → returns `{ posted: Integer, demoted: Integer }`. Raises `ApiUnavailableError` when a GitLab read/write fails. `diff_refs` unavailable → returns `nil` without posting anything.

- [ ] **Step 1: Write the failing test**

```ruby
# test/review_publisher_test.rb
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/review_contract'
require 'autodev/review_publisher'

# Autodev posts the review itself, with its own PAT (Autodev #74) — the skill
# stops before writing, which is its own invariant.
class ReviewPublisherTest < Minitest::Test
  FakeRefs = Struct.new(:base_sha, :start_sha, :head_sha)
  FakeMr = Struct.new(:diff_refs)
  FakeNote = Struct.new(:position)
  FakeNote2 = Struct.new(:body)
  FakeDiscussion = Struct.new(:notes)

  class StubClient
    attr_reader :discussions, :notes

    def initialize(refs: FakeRefs.new('b', 's', 'h'), anchor: true, raise_on_post: nil)
      @refs = refs
      @anchor = anchor
      @raise_on_post = raise_on_post
      @discussions = []
      @notes = []
    end

    def merge_request(_path, _iid) = FakeMr.new(@refs)

    def create_merge_request_discussion(_path, _iid, opts)
      raise @raise_on_post if @raise_on_post

      @discussions << opts
      FakeDiscussion.new([FakeNote.new(@anchor ? opts[:position] : nil)])
    end

    def create_merge_request_note(_path, _iid, body)
      @notes << body
      FakeNote.new(nil)
    end

    # `already_published?` reads this back; `auto_paginate` mirrors the gem's
    # paginated response.
    def merge_request_notes(_path, _iid, **_opts)
      stored = @notes.map { |b| FakeNote2.new(b) }
      Struct.new(:items) { def auto_paginate = items }.new(stored)
    end
  end

  def contract(findings, summary: 'S')
    ReviewContract.parse({ verdict: 'changes_requested', summary: summary, findings: findings }.to_json)
  end

  def publisher(client)
    ReviewPublisher.new(client: client, project_path: 'g/a', logger: NullLogger.new, locale: :fr)
  end

  def test_an_inline_finding_is_posted_as_a_positioned_discussion
    client = StubClient.new
    result = publisher(client).publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 12, 'severity' => 'error', 'body' => 'boom' }]
    ))
    assert_equal 1, result[:posted]
    position = client.discussions.first[:position]
    assert_equal 'a.rb', position[:new_path]
    assert_equal 12, position[:new_line]
    assert_equal 'h', position[:head_sha]
  end

  def test_the_summary_comment_is_posted_last
    client = StubClient.new
    publisher(client).publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
    ))
    assert_equal 1, client.notes.size
    assert_equal 1, client.discussions.size
  end

  def test_a_finding_that_will_not_anchor_is_demoted_not_lost
    client = StubClient.new(anchor: false)
    result = publisher(client).publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'unanchorable' }]
    ))
    assert_equal 1, result[:demoted]
    assert_includes client.notes.first, 'unanchorable'
  end

  def test_absent_diff_refs_post_nothing_and_are_not_a_verdict
    client = StubClient.new(refs: nil)
    assert_nil publisher(client).publish(mr_iid: 7, contract: contract([]))
    assert_empty client.discussions
    assert_empty client.notes
  end

  def test_a_second_pass_does_not_post_twice
    client = StubClient.new
    published = publisher(client)
    published.publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
    ))
    published.publish(mr_iid: 7, contract: contract(
      [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
    ))
    assert_equal 1, client.discussions.size
    assert_equal 1, client.notes.size
  end

  def test_a_gitlab_error_while_posting_raises_api_unavailable
    client = StubClient.new(raise_on_post: gitlab_response_error)
    assert_raises(ApiUnavailableError) do
      publisher(client).publish(mr_iid: 7, contract: contract(
        [{ 'file' => 'a.rb', 'line' => 1, 'severity' => 'error', 'body' => 'b' }]
      ))
    end
  end
end
```

`NullLogger` and `gitlab_response_error` come from `test/test_helper.rb`; if either is absent, add them there rather than inline (they are needed by later tasks too).

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/review_publisher_test.rb`
Expected: FAIL — `cannot load such file -- autodev/review_publisher`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/autodev/review_publisher.rb
# frozen_string_literal: true

# Posts a review that the project's skill produced but deliberately did not write
# (Autodev #74). Uses autodev's own PAT — the credential mr-review carries has
# been answering 401 since April.
class ReviewPublisher
  def initialize(client:, project_path:, logger:, locale:)
    @client = client
    @project_path = project_path
    @logger = logger
    @locale = locale
  end

  # nil = this poll could not conclude (no diff_refs yet). Not a verdict, and not
  # a review failure: the row is left where it is and the next cycle re-reads
  # (Autodev #62).
  def publish(mr_iid:, contract:)
    if already_published?(mr_iid)
      @logger.info("MR !#{mr_iid}: review already published, not posting again")
      return { posted: 0, demoted: 0 }
    end

    refs = diff_refs(mr_iid)
    return @logger.info("MR !#{mr_iid}: diff_refs not computed yet, review not published") || nil unless refs

    posted, demoted = post_inline(mr_iid, refs, contract.inline)
    post_summary(mr_iid, contract, demoted)
    { posted: posted.size, demoted: demoted.size }
  end

  private

  def diff_refs(mr_iid)
    mr = GitlabHelpers.answer(:merge_request) { @client.merge_request(@project_path, mr_iid) }
    refs = mr.diff_refs
    return nil unless refs && refs.head_sha

    refs
  end

  # One at a time, and each one checked: GitLab accepts a position it cannot
  # anchor and returns a note with a null `position`. A finding that will not
  # anchor is moved into the summary comment, never dropped — the rule is
  # PowerPanne's own review skill's.
  def post_inline(mr_iid, refs, findings)
    posted = []
    demoted = []
    findings.each do |finding|
      note = GitlabHelpers.answer(:mr_discussion) do
        @client.create_merge_request_discussion(@project_path, mr_iid,
                                                body: finding['body'].to_s,
                                                position: position_for(finding, refs))
      end
      anchored?(note) ? posted << finding : demoted << finding
    end
    [posted, demoted]
  end

  def position_for(finding, refs)
    { position_type: 'text', base_sha: refs.base_sha, start_sha: refs.start_sha,
      head_sha: refs.head_sha, old_path: finding['file'], new_path: finding['file'],
      new_line: finding['line'].to_i }
  end

  def anchored?(note)
    first = Array(note.respond_to?(:notes) ? note.notes : nil).first
    !first.nil? && !first.position.nil?
  end

  MARKER = '<!-- autodev:review -->'

  # Posted last, so its presence means the review went all the way. A cycle that
  # dies after the discussions but before this comment is retried, and without
  # this check the retry would post the discussions a second time.
  def already_published?(mr_iid)
    notes = GitlabHelpers.answer(:mr_notes) do
      @client.merge_request_notes(@project_path, mr_iid, per_page: 100).auto_paginate
    end
    notes.any? { |n| n.body.to_s.include?(MARKER) }
  end

  def post_summary(mr_iid, contract, demoted)
    body = Locales.t(:review_summary, locale: @locale, verdict: contract.verdict,
                                      summary: summary_body(contract, demoted))
    GitlabHelpers.answer(:mr_note) { @client.create_merge_request_note(@project_path, mr_iid, body) }
  end

  def summary_body(contract, demoted)
    lines = [contract.summary]
    (contract.summary_only + demoted).each do |f|
      where = f['file'] ? " (#{f['file']}:#{f['line']})" : ''
      lines << "- **#{f['severity']}**#{where} — #{f['body']}"
    end
    lines.reject { |l| l.to_s.strip.empty? }.join("\n\n")
  end
end
```

Add the require to `lib/autodev.rb`. Add to both `notifications.{fr,en}.yml`:

```yaml
  review_summary: "<!-- autodev:review -->\n:mag: **autodev** — revue automatique (verdict : %{verdict})\n\n%{summary}"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Itest test/review_publisher_test.rb`
Expected: PASS, 5 runs.

- [ ] **Step 5: Run the guards, the suite and RuboCop**

Run: `bundle exec ruby -Itest test/api_failure_is_not_a_verdict_test.rb` — expected PASS (the three new reads go through `answer`, so nothing new is declarable).
Run: `bundle exec ruby -Itest test/i18n_derived_keys_test.rb`, `bundle exec rake test`, `mise x ruby -- rubocop`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: autodev publishes the review its project skill declined to write (Autodev #74)"
```

---

### Task 4: `SkillReviewer` — clone, run the skill, read the contract

**Files:**
- Create: `lib/autodev/pipeline_monitor/skill_reviewer.rb`
- Modify: `lib/autodev/pipeline_monitor.rb` (include the module)
- Test: `test/skill_reviewer_test.rb`

**Interfaces:**
- Consumes: `@project_config['review_skill']` (Task 1), `ReviewContract.parse` (Task 2), `ReviewPublisher` (Task 3), and the existing `clone_and_checkout(work_dir, branch)`, `SkillsInjector.inject`, `danger_claude_prompt(work_dir, prompt, label:)`, `mr_review_timeout`.
- Produces: `review_with_skill(issue)` → `true` on a completed review, `false` on a review failure, `:inconclusive` when GitLab has not computed `diff_refs` yet. Raises `ApiUnavailableError` through to `PipelineMonitor#check`'s boundary.

- [ ] **Step 1: Write the failing test**

```ruby
# test/skill_reviewer_test.rb
# frozen_string_literal: true

require_relative 'rails_helper'

# The skill judges and stops; autodev posts (Autodev #74). What counts as a
# review failure is the whole point of this file.
class SkillReviewerTest < ActiveSupport::TestCase
  # Full construction is covered by the integration test in Task 5; here the
  # collaborators are stubbed so each failure mode is isolated.
  def reviewer(contract_json:, dc_raises: false, skill: 'mr-review', skill_present: true)
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@project_config, { 'review_skill' => skill })
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:clone_and_checkout) { |*| true }
    mon.define_singleton_method(:skill_available?) { |*| skill_present }
    mon.define_singleton_method(:mr_review_timeout) { 600 }
    mon.define_singleton_method(:danger_claude_prompt) do |*|
      raise ImplementationError, 'dc failed' if dc_raises

      File.write(mon.send(:review_contract_path, 7), contract_json) if contract_json
      'ok'
    end
    mon.define_singleton_method(:publish_review) { |*| { posted: 0, demoted: 0 } }
    mon
  end

  def issue = OpenStruct.new(issue_iid: 1, mr_iid: 7, branch_name: 'b', locale: 'fr')

  def test_a_clean_review_is_a_success
    json = { verdict: 'approve', summary: '', findings: [] }.to_json
    assert reviewer(contract_json: json).send(:review_with_skill, issue)
  end

  def test_a_missing_contract_file_is_a_failure
    refute reviewer(contract_json: nil).send(:review_with_skill, issue)
  end

  def test_an_off_schema_contract_is_a_failure
    refute reviewer(contract_json: '{"verdict":"lgtm"}').send(:review_with_skill, issue)
  end

  def test_a_danger_claude_crash_is_a_failure
    refute reviewer(contract_json: nil, dc_raises: true).send(:review_with_skill, issue)
  end

  def test_absent_diff_refs_are_inconclusive_not_a_success
    json = { verdict: 'changes_requested', summary: 'S',
             findings: [{ file: 'a.rb', line: 1, severity: 'error', body: 'b' }] }.to_json
    subject = reviewer(contract_json: json)
    subject.define_singleton_method(:publish_review) { |*| nil }
    assert_equal :inconclusive, subject.send(:review_with_skill, issue)
  end

  def test_a_declared_skill_missing_from_the_clone_is_named_not_silently_replaced
    subject = reviewer(contract_json: nil, skill_present: false)
    error = assert_raises(ConfigError) { subject.send(:review_with_skill, issue) }
    assert_match(/mr-review/, error.message)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/skill_reviewer_test.rb`
Expected: FAIL — `undefined method 'review_with_skill'`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/autodev/pipeline_monitor/skill_reviewer.rb
# frozen_string_literal: true

class PipelineMonitor
  # Runs the reviewed project's own review skill (Autodev #74).
  #
  # The skill judges and stops — both PowerPanne's and Fast's state in bold that
  # they write nothing without the developer's explicit go-ahead, and
  # `danger-claude` runs `claude -p`, so there is nobody to ask. That STOP is the
  # contract: autodev reads the findings back and posts them itself.
  module SkillReviewer
    private

    def review_with_skill(issue)
      skill = @project_config['review_skill']
      work_dir = "/tmp/autodev_review_#{@project_path.tr('/', '_')}_#{issue.issue_iid}"
      path = review_contract_path(issue.mr_iid)
      File.delete(path) if File.exist?(path)

      prepare_review_clone(work_dir, issue, skill)
      run_review_skill(work_dir, issue, skill, path)
      publish_from_contract(issue, path)
    rescue ImplementationError, ReviewContract::InvalidError => e
      log_error "MR !#{issue.mr_iid}: review via skill '#{skill}' failed: #{e.message}"
      false
    end

    # A clone failure is a review failure: unlike a GitLab error while posting,
    # here judgment never started.
    def prepare_review_clone(work_dir, issue, skill)
      clone_and_checkout(work_dir, issue.branch_name)
      SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)
      return if skill_available?(work_dir, skill)

      raise ConfigError,
            "project declares review_skill '#{skill}' but #{work_dir}/.claude/skills/#{skill}/SKILL.md " \
            'is missing — refusing to fall back to the mr-review binary, which would run a different process'
    end

    def skill_available?(work_dir, skill)
      File.exist?(File.join(work_dir, '.claude', 'skills', skill, 'SKILL.md'))
    end

    def run_review_skill(work_dir, issue, skill, path)
      danger_claude_prompt(work_dir, review_prompt(issue, skill, path), label: "-p (review via #{skill})")
    end

    def publish_from_contract(issue, path)
      raise ReviewContract::InvalidError, "contract file #{path} was not written" unless File.exist?(path)

      contract = ReviewContract.parse(File.read(path))
      # nil = no diff_refs yet. NOT a success: returning true here would increment
      # review_count, and the next poll would take the post-review branch, find no
      # discussion and deliver the MR without the review ever having been posted —
      # the exact shape Autodev #62 exists to remove.
      publish_review(issue, contract).nil? ? :inconclusive : true
    end

    def review_contract_path(mr_iid)
      "/tmp/autodev_review_#{@project_path.tr('/', '_')}_#{mr_iid}.json"
    end

    def review_prompt(issue, skill, path)
      <<~PROMPT
        Charge le skill `#{skill}`. Revois la merge request !#{issue.mr_iid} contre sa
        branche cible réelle, en appliquant intégralement la discipline du skill, y
        compris sa passe adversariale.

        Tu es en mode non interactif : il n'y a personne à qui demander une validation.
        N'écris rien sur GitLab — ni discussion, ni label, ni commentaire, ni note de
        ticket. Dépose tes constats consolidés dans #{path}, au format :

        {"verdict":"approve|changes_requested","summary":"…",
         "findings":[{"file":"chemin","line":12,"severity":"error|warning|info|nitpick","body":"…"}]}

        Un constat sans `file`/`line` est accepté : il sera rendu dans le commentaire
        de synthèse au lieu d'une discussion inline.
      PROMPT
    end

    def publish_review(issue, contract)
      ReviewPublisher.new(client: @client, project_path: @project_path,
                          logger: @logger, locale: issue.locale.to_sym)
                     .publish(mr_iid: issue.mr_iid, contract: contract)
    end
  end
end
```

Add `require_relative 'pipeline_monitor/skill_reviewer'` and `include SkillReviewer` to `lib/autodev/pipeline_monitor.rb`, next to the existing `Reviewer` include.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Itest test/skill_reviewer_test.rb`
Expected: PASS, 5 runs.

- [ ] **Step 5: Run the suite and RuboCop**

Run: `bundle exec rake test`, `mise x ruby -- rubocop`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: the review step can run the project's own review skill (Autodev #74)"
```

---

### Task 5: Fork the review step, and keep the counters honest

**Files:**
- Modify: `lib/autodev/pipeline_monitor/reviewer.rb` (`launch_review`, `execute_mr_review`)
- Modify: `CLAUDE.md` (PipelineMonitor section, Error Handling table, Key Design Decisions)
- Modify: `docs/usage/autodev-technical-usage.md`
- Test: `test/review_skill_path_test.rb`

**Interfaces:**
- Consumes: `review_with_skill(issue)` from Task 4, `@project_config['review_skill']` from Task 1.
- Produces: no new public surface. `launch_review` picks the path; `finalize_review_success` / `finalize_review_failure` are unchanged.

- [ ] **Step 1: Write the failing test**

```ruby
# test/review_skill_path_test.rb
# frozen_string_literal: true

require_relative 'rails_helper'

# Which path runs, and what each one does to the counters (Autodev #74).
class ReviewSkillPathTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup = setup_database

  def monitor(review_skill:, skill_result: true, binary_called: [])
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@project_config, review_skill ? { 'review_skill' => review_skill } : {})
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:log_activity) { |*| nil }
    mon.define_singleton_method(:snapshot) { |*| nil }
    mon.define_singleton_method(:review_with_skill) { |_| skill_result }
    mon.define_singleton_method(:execute_mr_review) { |_| binary_called << true and true }
    mon
  end

  def issue
    Issue.create!(project_path: 'g/a', issue_iid: 1, mr_iid: 7, status: 'reviewing',
                  review_count: 0, review_failure_count: 0, locale: 'fr')
  end

  def test_a_project_with_a_review_skill_does_not_run_the_binary
    called = []
    row = issue
    monitor(review_skill: 'mr-review', binary_called: called).send(:launch_review, row)
    assert_empty called
    assert_equal 1, row.reload.review_count
  end

  def test_a_project_without_a_review_skill_runs_the_binary
    called = []
    monitor(review_skill: nil, binary_called: called).send(:launch_review, issue)
    assert_equal [true], called
  end

  def test_a_skill_review_failure_increments_the_failure_counter
    row = issue
    monitor(review_skill: 'mr-review', skill_result: false).send(:launch_review, row)
    assert_equal 1, row.reload.review_failure_count
    assert_equal 0, row.reload.review_count
  end

  def test_an_inconclusive_review_touches_neither_counter_and_returns_to_the_watch
    row = issue
    monitor(review_skill: 'mr-review', skill_result: :inconclusive).send(:launch_review, row)
    assert_equal 0, row.reload.review_count
    assert_equal 0, row.reload.review_failure_count
    assert_equal 'checking_pipeline', row.reload.status
  end

  def test_an_api_failure_while_publishing_burns_no_budget
    row = issue
    mon = monitor(review_skill: 'mr-review')
    mon.define_singleton_method(:review_with_skill) { |_| raise ApiUnavailableError.new(:mr_note, 'boom') }
    assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
    assert_equal 0, row.reload.review_failure_count
    assert_equal 0, row.reload.review_count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/review_skill_path_test.rb`
Expected: FAIL — the binary is called even when a `review_skill` is declared.

- [ ] **Step 3: Fork the path**

In `lib/autodev/pipeline_monitor/reviewer.rb`, replace `launch_review`'s body:

```ruby
    def launch_review(issue)
      skill = @project_config['review_skill']
      log "Launching review for MR !#{issue.mr_iid} " \
          "(#{skill ? "skill '#{skill}'" : 'mr-review binary'}, review_count: #{issue.review_count})"
      log_activity(issue, :reviewing)
      # ApiUnavailableError propagates on purpose: a GitLab outage while we publish
      # is not a review failure and must not spend the budget (Autodev #62, #71).
      dispatch_review_outcome(issue, skill ? review_with_skill(issue) : execute_mr_review(issue))
    end

    # Three outcomes, not two. `:inconclusive` means GitLab had not computed the
    # MR's diff_refs yet, so nothing could be published: hand the row back to
    # `checking_pipeline` WITHOUT touching either counter, and the next cycle runs
    # the whole review again (review_count is still 0). Counting it as a success
    # would deliver the MR unreviewed; counting it as a failure would spend a
    # budget on a cycle that could not act (Autodev #71).
    def dispatch_review_outcome(issue, outcome)
      case outcome
      when :inconclusive
        log "MR !#{issue.mr_iid}: review not published this cycle, retrying next poll"
        issue.review_done!
      when true then finalize_review_success(issue)
      else finalize_review_failure(issue)
      end
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Itest test/review_skill_path_test.rb`
Expected: PASS, 4 runs.

- [ ] **Step 5: Update the docs**

In `CLAUDE.md`: the PipelineMonitor bullet for the first-review branch gains the fork and the clone; the Error Handling table gains a row for "declared review skill missing from the clone" and one for "diff_refs not computed yet"; the Key Design Decisions gain a bullet stating that the skill judges and autodev posts, and why. In `docs/usage/autodev-technical-usage.md`, document `review_skill` in the per-project settings table and the review step's two paths.

- [ ] **Step 6: Run everything**

Run: `bundle exec rake test`, then each touched test file on its own, then `mise x ruby -- rubocop`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: the review step runs the project's skill when one is declared (Autodev #74)"
```

---

### Task 6: Stop broadcasting every skill in the repo

**Files:**
- Modify: `lib/autodev/skills_injector.rb` (`skills_instruction`)
- Test: `test/skills_instruction_scope_test.rb`

**Interfaces:**
- Consumes: `SkillsInjector.inject`'s `:all_skills` (unchanged).
- Produces: `SkillsInjector.skills_instruction(all_skills)` now names only the skills autodev injected plus the project's convention skills, never the whole glob.

- [ ] **Step 1: Write the failing test**

```ruby
# test/skills_instruction_scope_test.rb
# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/skills_injector'

# The prompt line used to name every skill in the repo — 23 on powerpanne/core,
# including `hotfix` and `resolve-ticket`; 19 on ff/fast/core, including
# `ship-mep-to-production`. Telling Claude to load a ship-to-production skill
# before implementing a ticket is noise at best (Autodev #74).
class SkillsInstructionScopeTest < Minitest::Test
  def test_it_names_the_convention_skills
    line = SkillsInjector.skills_instruction(%w[rails-conventions test-patterns])
    assert_match(/rails-conventions/, line)
    assert_match(/test-patterns/, line)
  end

  def test_it_does_not_name_a_workflow_skill
    line = SkillsInjector.skills_instruction(%w[rails-conventions ship-mep-to-production hotfix mr-review])
    refute_match(/ship-mep-to-production/, line)
    refute_match(/hotfix/, line)
    refute_match(/mr-review/, line)
  end

  def test_no_relevant_skill_yields_no_instruction
    assert_equal '', SkillsInjector.skills_instruction(%w[hotfix])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/skills_instruction_scope_test.rb`
Expected: FAIL — `ship-mep-to-production` is named.

- [ ] **Step 3: Narrow the instruction**

```ruby
  # The convention skills are the ones a prompt should load: they describe how to
  # write code in this project. A workflow skill (`mr-review`, `hotfix`,
  # `ship-mep-to-production`) drives a process with its own trigger and its own
  # writes — it is named explicitly by the step that wants it, never broadcast.
  # The review step names its own (Autodev #74).
  PROMPT_SKILL_SUFFIXES = %w[-conventions -patterns].freeze

  def skills_instruction(all_skills)
    relevant = Array(all_skills).select { |s| PROMPT_SKILL_SUFFIXES.any? { |suffix| s.end_with?(suffix) } }
    return '' if relevant.empty?

    "- Avant de commencer, charge les skills suivants : #{relevant.map { |s| "`#{s}`" }.join(', ')}."
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Itest test/skills_instruction_scope_test.rb`
Expected: PASS, 3 runs.

- [ ] **Step 5: Run the suite and RuboCop**

Run: `bundle exec rake test` (existing `skills_injector` tests may assert the old wording — update them to the new scope, do not weaken them), `mise x ruby -- rubocop`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix: the prompt names the convention skills, not every skill in the repo (Autodev #74)"
```
