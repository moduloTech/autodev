# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'

# Detecting a `review_skill` the project's repository does not carry, *before*
# the first request of that project runs into it (Autodev #81, the ticket's
# option 2).
#
# The ticket priced this at "one clone per project". It is not: the question is
# "does this path exist on this ref", and GitLab's repository-files endpoint
# answers exactly that in one request — verified against source.modulotech.fr on
# 25/08/2026, where it separates powerpanne (SKILL.md on master and staging) from
# ff/fast/core (present on staging, absent from master) without cloning either.
#
# Everything here is fail-open. A probe that cannot reach GitLab must never be
# read as "the skill is missing": that would put a project's whole configuration
# under suspicion because of an outage, which is the Autodev #62 mistake in
# another costume.
# rubocop:disable Metrics/ClassLength -- one file per behaviour, and this
# behaviour has three axes that only read together: what the probe asks GitLab
# (and what it declines to ask), the three verdicts it can reach, and the
# passive card that reads the recorded one. Same call as IssueAbandonmentTest.
class ReviewSkillProbeTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  # Answers the repository-files read and counts what was asked. `clone` is a
  # tripwire: nothing in this path may shell out to git.
  class FakeClient
    Project = Struct.new(:default_branch)
    Commit = Struct.new(:id)

    attr_reader :asked, :confirmed

    def initialize(present: [], raising: nil, raising_on: nil, default_branch: 'main', refs: nil)
      @present = present
      @raising = raising
      @raising_on = raising_on
      @default_branch = default_branch
      # Every ref the repository has. Defaults to "all of them", so a test that
      # is not about a deleted branch does not have to say so.
      @refs = refs
      @asked = []
      @confirmed = []
    end

    def project(_path) = Project.new(@default_branch)

    def get_file(path, file_path, ref)
      @asked << [path, file_path, ref]
      raise @raising if @raising
      raise Errno::ECONNREFUSED if @raising_on == file_path
      raise Gitlab::Error::NotFound, fake_response(404) unless @present.include?([path, file_path, ref])

      Struct.new(:file_path).new(file_path)
    end

    # The Autodev #89 half: `404 Commit Not Found` and `404 File Not Found` are
    # both a `Gitlab::Error::NotFound`, so the ref itself is confirmed before the
    # configuration is accused.
    def commit(path, ref)
      @confirmed << [path, ref]
      raise Gitlab::Error::NotFound, fake_response(404) unless @refs.nil? || @refs.include?(ref)

      Commit.new('deadbeef')
    end

    private

    # The shape `Gitlab::Error::ResponseError#initialize` reads to build its
    # message: the status, the parsed body, and the request's base_uri + path.
    def fake_response(code)
      request = Struct.new(:base_uri, :path).new('https://gitlab.example', '/api/v4')
      Struct.new(:code, :parsed_response, :request).new(code, {}, request)
    end
  end

  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  SKILL_PATH = '.claude/skills/prepare-mr/SKILL.md'
  # The flat layout `SkillsInjector.migrate_legacy_skills` moves into the one
  # above, inside every clone, before the review step looks.
  LEGACY_SKILL_PATH = '.claude/skills/prepare-mr.md'

  def setup
    setup_database
  end

  def fast(**overrides)
    { 'path' => 'modulosource/ff/fast/core', 'target_branch' => 'staging',
      'review_skill' => 'prepare-mr' }.merge(overrides)
  end

  def probe(projects, client)
    Autodev::ReviewSkillProbe.probe!(config: {}, projects: projects, client: client,
                                     logger: NullLogger.new)
  end

  def statuses(verdicts) = verdicts.map { |verdict| [verdict[:path], verdict[:status]] }

  # --- what it asks, and what it does not ---------------------------------

  def test_it_asks_gitlab_for_the_skill_file_on_the_projects_target_branch
    client = FakeClient.new(present: [['modulosource/ff/fast/core', SKILL_PATH, 'staging']])
    probe([fast], client)

    assert_equal [['modulosource/ff/fast/core', SKILL_PATH, 'staging']], client.asked
  end

  # The cost the ticket worried about. One request answers the question; the
  # review step's own clone is the only clone in the product's review path.
  def test_one_project_costs_one_request
    client = FakeClient.new(present: [['modulosource/ff/fast/core', SKILL_PATH, 'staging']])
    probe([fast], client)

    assert_equal 1, client.asked.size
  end

  def test_a_project_declaring_no_review_skill_is_not_probed_at_all
    client = FakeClient.new
    verdicts = probe([{ 'path' => 'g/a', 'target_branch' => 'main' }], client)

    assert_empty client.asked
    assert_empty verdicts
  end

  # `''` is truthy in Ruby, and `Reviewer#launch_review` reads a blank as "no
  # skill declared". The probe has to agree, or it reports a fault on a project
  # that takes the binary path.
  def test_a_blank_review_skill_reads_as_absent
    client = FakeClient.new
    probe([fast('review_skill' => '  ')], client)

    assert_empty client.asked
  end

  # Autodev injects these four into every clone itself (SkillsInjector), so they
  # are available whatever the repository holds. Asking GitLab about them would
  # report a fault that the review step will never hit.
  def test_a_skill_autodev_injects_itself_needs_no_repository_copy
    client = FakeClient.new
    verdicts = probe([fast('review_skill' => SkillsInjector::SKILL_NAMES.first)], client)

    assert_empty client.asked
    assert_equal [['modulosource/ff/fast/core', 'present']], statuses(verdicts)
  end

  # About the ref, not the number of questions: with no layout present the probe
  # asks about both, and each has to be asked on the repository's default branch.
  def test_the_repository_default_branch_is_used_when_no_target_branch_is_configured
    client = FakeClient.new(default_branch: 'trunk')
    probe([fast.except('target_branch')], client)

    assert_equal [['modulosource/ff/fast/core', 'trunk']],
                 client.asked.map { |path, _file, ref| [path, ref] }.uniq
  end

  # --- the three verdicts --------------------------------------------------

  def test_a_present_skill_file_reads_as_present
    client = FakeClient.new(present: [['modulosource/ff/fast/core', SKILL_PATH, 'staging']])

    assert_equal [['modulosource/ff/fast/core', 'present']], statuses(probe([fast], client))
  end

  # The production case of 25/08/2026: ff/fast/core carries the skill on
  # `staging` and not on `master`, so switching its target branch is what arms
  # the fault. The probe reads the branch actually configured.
  def test_a_skill_absent_from_the_configured_branch_reads_as_missing
    client = FakeClient.new(present: [['modulosource/ff/fast/core', SKILL_PATH, 'staging']])
    verdicts = probe([fast('target_branch' => 'master')], client)

    assert_equal [['modulosource/ff/fast/core', 'missing']], statuses(verdicts)
  end

  def test_a_missing_verdict_carries_the_skill_the_branch_and_the_expected_path
    client = FakeClient.new
    verdict = probe([fast('target_branch' => 'master')], client).first

    assert_equal ['prepare-mr', 'master', SKILL_PATH],
                 [verdict[:skill], verdict[:ref], verdict[:expected]]
  end

  # The defect this file was blind to. `SkillsInjector.inject` runs
  # `migrate_legacy_skills` *before* `SkillReviewer#skill_available?` looks, and
  # that pass moves `.claude/skills/<name>.md` to `<name>/SKILL.md` inside the
  # clone. So a repository still on the flat layout reviews perfectly well, and a
  # probe that only knows the directory layout records it `missing` — the health
  # card then tells the operator that every request of that project stops at the
  # review step, which is false. Same ruling as `unknown` vs `missing`: this
  # class may not accuse a working configuration.
  def test_the_flat_legacy_layout_reads_as_present
    client = FakeClient.new(present: [['modulosource/ff/fast/core', LEGACY_SKILL_PATH, 'staging']])

    assert_equal [['modulosource/ff/fast/core', 'present']], statuses(probe([fast], client))
  end

  # The sobriety the ticket asked for is kept where it matters: the directory
  # layout is asked first, so a healthy fleet still costs one request per project
  # per cycle. Only a repository that does *not* carry it pays for the second
  # question.
  def test_the_legacy_layout_is_only_asked_when_the_directory_layout_is_absent
    client = FakeClient.new(present: [['modulosource/ff/fast/core', LEGACY_SKILL_PATH, 'staging']])
    probe([fast], client)

    asked = client.asked.map { |_path, file, ref| [file, ref] }

    assert_equal [[SKILL_PATH, 'staging'], [LEGACY_SKILL_PATH, 'staging']], asked
  end

  # Both layouts absent is the only thing that may read as `missing`.
  def test_neither_layout_present_still_reads_as_missing
    client = FakeClient.new

    assert_equal [['modulosource/ff/fast/core', 'missing']], statuses(probe([fast], client))
  end

  # Before `missing` may be concluded, the ref itself is confirmed — and only
  # then, so the healthy case pays nothing (Autodev #89).
  def test_the_ref_is_confirmed_only_when_the_configuration_is_about_to_be_accused
    present = FakeClient.new(present: [['modulosource/ff/fast/core', SKILL_PATH, 'staging']])
    probe([fast], present)
    absent = FakeClient.new
    probe([fast], absent)

    assert_empty present.confirmed
    assert_equal [['modulosource/ff/fast/core', 'staging']], absent.confirmed
  end

  # The trap this shares with the review step (Autodev #89): GitLab answers
  # `404 Commit Not Found` for a ref that does not exist and `404 File Not Found`
  # for a file that does not, and both arrive as `Gitlab::Error::NotFound`. A
  # `target_branch` that has been deleted or renamed therefore looked exactly
  # like a missing skill, and the health card would have accused a configuration
  # whose skill is perfectly present on the branch that does exist.
  def test_a_configured_branch_the_repository_does_not_have_is_unknown_not_missing
    client = FakeClient.new(refs: ['staging'])

    assert_equal [['modulosource/ff/fast/core', 'unknown']],
                 statuses(probe([fast('target_branch' => 'gone')], client))
  end

  # And the fail-open rule survives the second question: a GitLab error on the
  # legacy read is still `unknown`, never `missing`.
  def test_an_outage_on_the_second_question_is_unknown_not_missing
    client = FakeClient.new(raising_on: LEGACY_SKILL_PATH)

    assert_equal [['modulosource/ff/fast/core', 'unknown']], statuses(probe([fast], client))
  end

  # Fail-open. An unreachable GitLab is not a verdict on the configuration
  # (Autodev #62): `unknown` is reported, and the health check below ignores it.
  def test_an_unreachable_gitlab_reads_as_unknown_never_as_missing
    client = FakeClient.new(raising: Errno::ECONNREFUSED)

    assert_equal [['modulosource/ff/fast/core', 'unknown']], statuses(probe([fast], client))
  end

  # A skill name that cannot be a skill directory can be answered without asking
  # GitLab, and it is the one shape a form-level check would have caught
  # (the ticket's option 3, folded in here where it produces a real verdict
  # instead of a second opinion).
  def test_a_name_that_cannot_be_a_skill_directory_is_rejected_without_a_request
    client = FakeClient.new
    verdicts = probe([fast('review_skill' => '../../etc')], client)

    assert_empty client.asked
    assert_equal [['modulosource/ff/fast/core', 'missing']], statuses(verdicts)
  end

  # --- the persisted verdict, and the card that reads it -------------------

  def test_the_verdict_is_persisted_and_read_back_passively
    client = FakeClient.new
    probe([fast('target_branch' => 'master')], client)
    state = Autodev::ReviewSkillProbe.state(config: {})

    assert_equal(['modulosource/ff/fast/core'], state[:missing].map { |m| m['path'] })
    refute_nil state[:checked_at]
  end

  def test_with_no_probe_on_file_the_state_is_empty_and_dated_nowhere
    state = Autodev::ReviewSkillProbe.state(config: {})

    assert_equal [[], nil], [state[:missing], state[:checked_at]]
  end

  # `HealthReport` is passive by contract — it never calls GitLab — so it reads
  # the verdict the poll cycle recorded, exactly as `check_claude_usage` reads
  # `UsageGate`'s.
  def test_the_health_card_warns_when_a_declared_skill_is_missing
    probe([fast('target_branch' => 'master')], FakeClient.new)
    check = Autodev::HealthReport.new(config: {}).check(:review_skill)[:checks][:review_skill]

    assert_equal :warn, check[:status]
    assert_includes check[:meta].values.join(' '), 'modulosource/ff/fast/core'
  end

  def test_the_health_card_is_green_when_every_declared_skill_is_there
    client = FakeClient.new(present: [['modulosource/ff/fast/core', SKILL_PATH, 'staging']])
    probe([fast], client)

    assert_equal :ok, Autodev::HealthReport.new(config: {}).check(:review_skill)[:status]
  end

  def test_the_health_card_is_green_when_nothing_was_ever_probed
    assert_equal :ok, Autodev::HealthReport.new(config: {}).check(:review_skill)[:status]
  end

  # An `unknown` must not raise the card either: the operator would be told a
  # configuration is broken because GitLab was down.
  def test_an_unknown_verdict_does_not_raise_the_card
    probe([fast], FakeClient.new(raising: Errno::ECONNREFUSED))

    assert_equal :ok, Autodev::HealthReport.new(config: {}).check(:review_skill)[:status]
  end

  # The rows are machinery: written on a clock, read only as the newest one, and
  # deleted past the retention window. They must never reach the issue timeline
  # or the sparkline.
  def test_the_probe_rows_are_machinery_and_never_user_visible
    probe([fast], FakeClient.new)

    assert_includes ActivityEvent::MACHINERY_KINDS, Autodev::ReviewSkillProbe::KIND
    assert_empty ActivityEvent.user_visible.where(kind: Autodev::ReviewSkillProbe::KIND)
  end
end
# rubocop:enable Metrics/ClassLength
