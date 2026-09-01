# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'
require 'tmpdir'

# Is the GitLab credential `mr-review` runs with still accepted? (Autodev #80.)
#
# The defect this answers is not "a token expired" — tokens expire. It is that
# this one expired in April 2026 and nothing said so until August: 23 requests of
# a single project were abandoned on `review_failures_exhausted`, the health card
# fired on 25 distinct issues on 11/08, and the cause (`401 Token was revoked` on
# the call to merge request 11258) sat in a log nobody correlated. Four months of
# silence on a credential nothing was watching.
#
# Two properties make this probe worth having, and both are load-bearing:
#
#   * **it is armed by the population, not by the clock.** A probe that tests a
#     credential nothing uses produces a card nobody acts on, which is the exact
#     inverse of the rule `HealthReport` gives itself ("a state this card flags
#     but nothing can revive would be a card nobody can act on"). Both configured
#     projects have declared a `review_skill` since 25/08, so no review reaches
#     the binary today and the probe does nothing at all. It arms itself on the
#     first project onboarded without one — the moment the ticket bites again;
#   * **a read that failed accuses nobody.** `revoked` is reached on 401/403 and
#     on nothing else. A 500, a timeout, an absent or unparseable configuration
#     file are all `unknown`, which the card reads as "no news" — Autodev #62's
#     rule applied to a probe.
# rubocop:disable Metrics/ClassLength -- one file per behaviour, and this
# behaviour has three axes that only read together: what arms the probe, the
# three verdicts it can reach, and what it is allowed to persist. Same call as
# ReviewSkillProbeTest.
class MrReviewTokenProbeTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  # Answers `client.user` — the one call `IssueNotifier#assign_to_self` already
  # makes — and counts what was asked. `asked` is the tripwire: an unarmed probe
  # must not reach GitLab at all.
  class FakeClient
    User = Struct.new(:id, :username)

    attr_reader :asked

    def initialize(raising: nil)
      @raising = raising
      @asked = []
    end

    def user
      @asked << :user
      raise @raising if @raising

      User.new(1, 'autodev')
    end
  end

  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  # A real-shaped PAT, so the "no secret in the payload" assertion below is about
  # the thing that would actually leak.
  TOKEN = 'glpat-Autodev80ProbeToken'
  SEPARATE_TOKEN = 'glpat-MrReviewOwnToken80'
  CONFIG = { 'gitlab_url' => 'https://gitlab.example', 'gitlab_token' => TOKEN }.freeze

  # The population that arms the probe: a project with no `review_skill` reviews
  # through the binary.
  ON_THE_BINARY = { 'path' => 'group/on-the-binary' }.freeze
  ON_A_SKILL = { 'path' => 'group/on-a-skill', 'review_skill' => 'prepare-mr' }.freeze

  def setup
    setup_database
  end

  def probe(projects, client: FakeClient.new, config: CONFIG, config_path: '/nonexistent/mr-review.yml')
    Autodev::MrReviewTokenProbe.probe!(config: config, projects: projects, client: client,
                                       logger: NullLogger.new, config_path: config_path)
  end

  def recorded = ActivityEvent.where(kind: Autodev::MrReviewTokenProbe::KIND).order(:id).last

  # Reading the other tool's configuration file is a side effect like any other,
  # and an unarmed probe may not have one.
  def refusing_file_reads(&)
    tripwire = ->(*) { flunk('the probe read a file it had no reason to open') }
    Autodev::MrReviewTokenProbe.stub(:read_config_file, tripwire, &)
  end

  def gitlab_error(klass, code)
    request = Struct.new(:base_uri, :path).new('https://gitlab.example', '/api/v4/user')
    klass.new(Struct.new(:code, :parsed_response, :request).new(code, {}, request))
  end

  # --- what arms it -------------------------------------------------------

  # The decision this whole class rests on. Every project on the skill path means
  # nothing reviews through the binary, so the credential it carries is not in
  # use — and a verdict on it is a card nobody can act on.
  def test_a_fleet_entirely_on_the_skill_path_costs_nothing_at_all
    client = FakeClient.new

    refusing_file_reads { probe([ON_A_SKILL, ON_A_SKILL], client: client) }

    assert_empty client.asked
    assert_nil recorded
  end

  def test_one_project_without_a_review_skill_arms_it
    client = FakeClient.new
    probe([ON_A_SKILL, ON_THE_BINARY], client: client)

    assert_equal [:user], client.asked
    assert_equal 'alive', recorded.payload['status']
  end

  # `''` is truthy in Ruby and `Project#to_project_config` emits every column, so
  # a blank reads as "no skill declared" here exactly as it does in
  # `Reviewer#launch_review` and in `bin/autodev`'s boot warning.
  def test_a_blank_review_skill_still_relies_on_the_binary
    client = FakeClient.new
    probe([ON_A_SKILL.merge('review_skill' => '   ')], client: client)

    assert_equal [:user], client.asked
  end

  # The predicate is `bin/autodev`'s, shared rather than restated — the lesson
  # Autodev #72 and #81 each paid for once.
  def test_the_boot_warning_and_the_probe_ask_the_same_question
    assert Autodev::MrReviewTokenProbe.relied_upon_by_any?([ON_THE_BINARY])
    refute Autodev::MrReviewTokenProbe.relied_upon_by_any?([ON_A_SKILL])
  end

  # --- the three verdicts --------------------------------------------------

  def test_one_armed_cycle_costs_one_request
    client = FakeClient.new
    probe([ON_THE_BINARY], client: client)

    assert_equal 1, client.asked.size
  end

  def test_a_401_reads_as_revoked
    probe([ON_THE_BINARY], client: FakeClient.new(raising: gitlab_error(Gitlab::Error::Unauthorized, 401)))

    assert_equal 'revoked', recorded.payload['status']
  end

  def test_a_403_reads_as_revoked
    probe([ON_THE_BINARY], client: FakeClient.new(raising: gitlab_error(Gitlab::Error::Forbidden, 403)))

    assert_equal 'revoked', recorded.payload['status']
  end

  def test_a_revoked_verdict_is_recorded_as_a_warning
    probe([ON_THE_BINARY], client: FakeClient.new(raising: gitlab_error(Gitlab::Error::Unauthorized, 401)))

    assert_equal 'warn', recorded.level
  end

  # The non-regression that matters most. Everything below is a read that did not
  # happen, and a read that did not happen says nothing about the credential.
  def test_a_server_error_is_unknown_never_revoked
    probe([ON_THE_BINARY], client: FakeClient.new(raising: gitlab_error(Gitlab::Error::InternalServerError, 500)))

    assert_equal 'unknown', recorded.payload['status']
  end

  def test_an_unreachable_gitlab_is_unknown_never_revoked
    probe([ON_THE_BINARY], client: FakeClient.new(raising: Errno::ECONNREFUSED))

    assert_equal 'unknown', recorded.payload['status']
  end

  def test_a_timeout_is_unknown_never_revoked
    probe([ON_THE_BINARY], client: FakeClient.new(raising: Net::OpenTimeout))

    assert_equal 'unknown', recorded.payload['status']
  end

  # With no credential in autodev's own configuration, the fallback is the file
  # `mr-review` reads for itself. Absent, it answers nothing — and a probe with
  # no credential to present may not call GitLab either.
  def test_an_absent_configuration_file_is_unknown_and_asks_nothing
    client = FakeClient.new
    probe([ON_THE_BINARY], client: client, config: {})

    assert_empty client.asked
    assert_equal 'unknown', recorded.payload['status']
  end

  def test_an_unreadable_configuration_file_is_unknown_never_revoked
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, "gitlab_api_token: [unclosed\n  : :\n")
      probe([ON_THE_BINARY], config: {}, config_path: path)

      assert_equal 'unknown', recorded.payload['status']
    end
  end

  def test_the_file_supplies_the_credential_when_autodev_declares_none
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, "gitlab_api_token: #{SEPARATE_TOKEN}\n")
      probe([ON_THE_BINARY], config: {}, config_path: path)

      assert_equal %w[alive mr_review_config], recorded.payload.values_at('status', 'source')
    end
  end

  # --- which credential, and what is written down --------------------------

  # Mutualisation by default: mr-review is handed autodev's own token unless the
  # operator wrote a separation into autodev's configuration.
  def test_the_shared_token_is_the_default_subject
    probe([ON_THE_BINARY])

    assert_equal 'gitlab_token', recorded.payload['source']
  end

  def test_a_declared_mr_review_token_is_the_subject_instead
    probe([ON_THE_BINARY], config: CONFIG.merge('mr_review_token' => SEPARATE_TOKEN))

    assert_equal 'mr_review_token', recorded.payload['source']
  end

  # The rows outlive the cycle and are read back by a health card, so what they
  # carry is the name of a configuration key, never the value behind it.
  def test_no_secret_reaches_the_persisted_payload
    probe([ON_THE_BINARY], config: CONFIG.merge('mr_review_token' => SEPARATE_TOKEN))

    refute_includes recorded.payload_json, SEPARATE_TOKEN
    refute_includes recorded.payload_json, TOKEN
  end

  # Machinery: written on a clock, read only as the newest one, dropped past the
  # retention window. It must never reach the timeline or the SSE feed.
  def test_the_probe_rows_are_machinery_and_never_user_visible
    probe([ON_THE_BINARY])

    assert_includes ActivityEvent::MACHINERY_KINDS, Autodev::MrReviewTokenProbe::KIND
    assert_empty ActivityEvent.user_visible.where(kind: Autodev::MrReviewTokenProbe::KIND)
  end

  # --- the recorded state, read back passively -----------------------------

  def test_the_verdict_is_read_back_passively
    probe([ON_THE_BINARY], client: FakeClient.new(raising: gitlab_error(Gitlab::Error::Unauthorized, 401)))
    state = Autodev::MrReviewTokenProbe.state(config: {})

    assert_equal 'revoked', state[:status]
    refute_nil state[:checked_at]
  end

  def test_with_no_probe_on_file_the_state_is_unknown_and_dated_nowhere
    state = Autodev::MrReviewTokenProbe.state(config: {})

    assert_equal ['unknown', nil], [state[:status], state[:checked_at]]
  end

  # Fail open on age, like every other recorded verdict here: two poll intervals,
  # never under ten minutes. A `revoked` nobody refreshed is not a live fault.
  def test_a_verdict_past_its_ttl_reads_as_unknown
    probe([ON_THE_BINARY], client: FakeClient.new(raising: gitlab_error(Gitlab::Error::Unauthorized, 401)))
    recorded.update!(created_at: Time.now.utc - 3600)
    state = Autodev::MrReviewTokenProbe.state(config: { 'poll_interval' => 300 })

    assert_equal ['unknown', nil], [state[:status], state[:checked_at]]
  end

  # --- the cycle -----------------------------------------------------------

  # One probe per cycle, over the same project list the dispatchers get — the
  # shape `UsageGate` and `ReviewSkillProbe` already have, for the same reason:
  # `HealthReport` is passive by contract, so the cycle is what reads live.
  def test_the_poll_cycle_probes_once_over_its_own_projects
    calls = []
    stub = ->(config:, projects:, logger: nil) { (calls << [config, projects, logger]) && nil }

    Autodev::MrReviewTokenProbe.stub(:probe!, stub) { run_poll_cycle }

    assert_equal 1, calls.size
    assert_equal(%w[group/on-the-binary], calls.first[1].map { |project| project['path'] })
  end

  # An advisory check must never be the thing that stops a poll cycle — the same
  # ruling `bin/autodev`'s `warn_rejected_numeric_settings` carries.
  def test_a_probe_that_raises_does_not_break_the_cycle
    stub = ->(**) { raise StandardError, 'gitlab down' }

    dispatched = Autodev::MrReviewTokenProbe.stub(:probe!, stub) { run_poll_cycle }

    assert_equal %w[group/on-the-binary], dispatched
  end

  private

  # Minimal AutodevPollJob drive: the quota checker and the dispatcher are stood
  # in for, so what is left is the orchestration this file cares about.
  def run_poll_cycle
    dispatched = []
    Config.stub(:load, { 'projects' => [ON_THE_BINARY.dup] }) do
      UsageChecker.stub(:new, quota_available) do
        Autodev::PollDispatcher.stub(:new, recording_dispatcher(dispatched)) { AutodevPollJob.new.perform }
      end
    end
    dispatched
  end

  def quota_available
    Object.new.tap { |checker| checker.define_singleton_method(:available?) { true } }
  end

  def recording_dispatcher(dispatched)
    lambda do |config:, project_config:, logger:, usage_ok: true|
      _ = [config, logger, usage_ok]
      Object.new.tap { |obj| obj.define_singleton_method(:dispatch) { dispatched << project_config['path'] } }
    end
  end
end
# rubocop:enable Metrics/ClassLength
