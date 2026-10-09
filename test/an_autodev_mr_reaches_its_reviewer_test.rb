# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'
require_relative 'stub_logger'

# Autodev #90 — when autodev delivers, the merge request reaches its reviewer.
#
# Measured on 08/10/2026: 38 of the last 50 autodev merge requests on
# powerpanne/core carry `MR::` labels, and every one was posted by hand
# afterwards (label events: `ciappa_m`, 07/10/2026). The project's scripts
# compute; autodev writes with its own token and reads every write back.
#
# The container is faked at `run_with_timeout` — the seam every danger-claude
# call goes through — and GitLab by a client that applies edits the way GitLab
# CE does, including dropping what CE drops.
class AnAutodevMrReachesItsReviewerTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  # rubocop:disable Style/FormatStringToken
  SIZE = ['bin/ci/mr_size', '--mr', '%{mr_iid}', '--json'].freeze
  COVERAGE = ['bin/ci/mr_coverage', '--base', '%{base_sha}', '--head', '%{head_sha}', '--json'].freeze
  DRAW = ['bin/ci/reviewer_draw', '--size', '%{size}', '%{red_flag}', '--author', '%{mr_author}', '--json'].freeze
  # rubocop:enable Style/FormatStringToken
  PROJECT_CONFIG = { 'path' => 'group/app', 'labels_todo' => ['To do'], 'label_doing' => 'Doing',
                     'label_done' => 'Development::Awaiting Feature Review',
                     'review_size_command' => SIZE, 'review_coverage_command' => COVERAGE,
                     'reviewer_draw_command' => DRAW }.freeze
  BASE = 'b' * 40
  HEAD = 'h' * 40
  USERS = { 'billau_l' => [27, 'Lucas Billaudot'], 'alexan_a' => [194, 'Antoine ALEXANIAN'],
            'bernar_a' => [337, 'Alexandre BERNARD'] }.freeze
  REVIEWER_LABELS = %w[MR::Reviewer::Lucas MR::Reviewer::Antoine MR::Reviewer::Alexandre MR::Reviewer::Team].freeze

  Status = Struct.new(:exitstatus)

  # GitLab CE as far as this feature touches it: one reviewer, one assignee, a
  # second reviewer silently dropped; labels added and removed by name.
  class FakeGitlab
    attr_reader :edits, :mr
    attr_accessor :drop_reviewers, :drop_labels, :drop_assignees, :keep_labels

    def initialize(labels: [], reviewers: [], diff_refs: { 'base_sha' => BASE, 'head_sha' => HEAD })
      @mr = { 'iid' => 7, 'labels' => labels, 'reviewers' => reviewers, 'assignees' => [],
              'source_branch' => 'autodev/42-x', 'target_branch' => 'master',
              'author' => { 'username' => 'autodev_bot' }, 'diff_refs' => diff_refs }
      @edits = []
      @drop_labels = []
      @keep_labels = []
    end

    def merge_request(_path, _iid) = deep_copy(@mr)

    def users(username:)
      id, name = USERS[username]
      id ? [{ 'id' => id, 'username' => username, 'name' => name }] : []
    end

    def labels(_path, search:, per_page:) # rubocop:disable Lint/UnusedMethodArgument
      REVIEWER_LABELS.select { |l| l.start_with?(search) }.map { |name| { 'name' => name } }
    end

    def edit_merge_request(_path, _iid, attrs)
      @edits << attrs
      apply_labels(attrs)
      apply_people(attrs)
      deep_copy(@mr)
    end

    private

    def apply_labels(attrs)
      remove = attrs[:remove_labels].to_s.split(',') - @keep_labels
      add = attrs[:add_labels].to_s.split(',') - @drop_labels
      @mr['labels'] = (@mr['labels'] - remove + add).uniq
    end

    def apply_people(attrs)
      @mr['reviewers'] = Array(attrs[:reviewer_ids]).first(1).map { |id| { 'id' => id } } if attrs.key?(:reviewer_ids)
      @mr['reviewers'] = [] if drop_reviewers
      @mr['assignees'] = [{ 'id' => attrs[:assignee_id] }] if attrs.key?(:assignee_id)
      @mr['assignees'] = [] if drop_assignees
    end

    def deep_copy(obj) = Marshal.load(Marshal.dump(obj))
  end

  setup do
    setup_database
    @client = FakeGitlab.new
    @answers = { 'mr_size' => [0, { 'class' => 'M' }], 'mr_coverage' => [0, { 'zone' => 'medium' }],
                 'reviewer_draw' => [0, { 'drawn' => %w[alexan_a bernar_a], 'postponed' => false }] }
    @calls = []
    @entries = []
    @issue = Issue.create!(project_path: 'group/app', issue_iid: 42, status: 'done', mr_iid: 7,
                           branch_name: 'autodev/42-x')
  end

  def monitor(config = PROJECT_CONFIG)
    PipelineMonitor.allocate.tap do |m|
      m.send(:init_runner, client: @client, config: {}, project_config: config, logger: StubLogger.new,
                           token: 'glpat-secret', **{})
      m.instance_variable_set(:@gitlab_url, 'https://gitlab.example.com')
      fake_world(m)
    end
  end

  # The container answers per script; git commands succeed. `@calls` records
  # what the container was asked to run, and the env file it was handed.
  def fake_world(target)
    test = self
    target.define_singleton_method(:clone_and_checkout) { |_dir, _branch| nil }
    target.define_singleton_method(:run_cmd_status) { |*, **| ['', '', true] }
    target.define_singleton_method(:run_cmd) { |*, **| '' }
    target.define_singleton_method(:log_activity) { |_issue, key, **vars| test.record_entry(key, vars) }
    target.define_singleton_method(:run_with_timeout) { |cmd, args, **| test.container(cmd, args) }
  end

  def record_entry(key, vars) = @entries << [key, vars]

  def container(cmd, args)
    shell = args[args.index('-s') + 1]
    @calls << { cmd: cmd, args: args, shell: shell, **env_file(args) }
    script = @answers.keys.find { |name| shell.include?(name) }
    code, json = @answers.fetch(script)
    out = json.is_a?(String) ? json : "noise from the entrypoint\n#{JSON.generate(json)}\n"
    [out, "#{script}: stderr line\n", code.zero?, Status.new(code)]
  end

  def env_file(args)
    mount = args[args.index('-v') + 1].split(':').first
    { env: File.read(mount), mode: File.stat(mount).mode & 0o777 }
  end

  def fetch_commands(present:)
    m = monitor
    fetched = []
    m.define_singleton_method(:run_cmd_status) do |cmd, **|
      ['', '', present.any? { |sha| cmd.last == "#{sha}^{commit}" }]
    end
    m.define_singleton_method(:run_cmd) { |cmd, **| fetched << cmd if cmd[1] == 'fetch' }
    m.send(:hand_off_for_review, @issue)
    fetched
  end

  def hand_off(config = PROJECT_CONFIG)
    monitor(config).send(:hand_off_for_review, @issue)
  end

  def labels = @client.mr['labels']
  def entry_keys = @entries.map(&:first)

  def rendered(locale = :fr)
    key, vars = @entries.first
    I18n.t(:"activity_#{key}", locale: locale, **vars, raise: true)
  end

  # GitLab applies the write, then the read-back made right after it times
  # out — `Net::ReadTimeout` on the check, not on the write.
  def read_back_times_out_after(added_label)
    client = @client
    real = client.method(:merge_request)
    client.define_singleton_method(:merge_request) do |path, iid|
      raise Net::ReadTimeout if client.edits.last.to_h[:add_labels].to_s.split(',').include?(added_label)

      real.call(path, iid)
    end
  end

  # -- The nominal handoff ----------------------------------------------------

  test 'a delivery writes size, coverage, the reviewer labels, the reviewer and the assignee, then ready' do # rubocop:disable Minitest/MultipleAssertions
    hand_off

    assert_equal %w[MR::Size::M MR::TestCoverage::Standard MR::Reviewer::Antoine MR::Reviewer::Alexandre
                    MR::ReadyForReview].sort, labels.sort
    assert_equal [{ 'id' => 194 }], @client.mr['reviewers']
    assert_equal [{ 'id' => 337 }], @client.mr['assignees']
    assert_equal [:review_handoff_ready], entry_keys
    assert_equal({ size: 'MR::Size::M', coverage: 'MR::TestCoverage::Standard', reviewer: 'alexan_a',
                   assignee: 'bernar_a' }, @entries.first.last)
  end

  test 'MR::ReadyForReview is written last, in a write of its own' do
    hand_off

    assert_equal 'MR::ReadyForReview', @client.edits.last[:add_labels]
    refute_includes @client.edits.first[:add_labels].split(','), 'MR::ReadyForReview'
  end

  test 'one drawn developer is both the reviewer and the assignee' do
    @answers['reviewer_draw'] = [0, { 'drawn' => %w[billau_l], 'postponed' => false }]
    hand_off

    assert_equal [{ 'id' => 27 }], @client.mr['reviewers']
    assert_equal [{ 'id' => 27 }], @client.mr['assignees']
    assert_equal ['MR::Reviewer::Lucas'], labels.grep(/Reviewer/)
  end

  test 'the reviewer label is the first word of the GitLab name, never the username' do
    hand_off

    assert_equal %w[MR::Reviewer::Alexandre MR::Reviewer::Antoine], labels.grep(/Reviewer/).sort
    refute(labels.any? { |l| l.include?('alexan_a') || l.include?('bernar_a') })
  end

  # -- Placeholders and the container ------------------------------------------

  test 'placeholders are substituted per element and the red flag appears only on a red zone' do # rubocop:disable Minitest/MultipleAssertions
    hand_off
    draw = @calls.find { |c| c[:shell].include?('reviewer_draw') }[:shell]

    assert_includes @calls.first[:shell], 'bin/ci/mr_size --mr 7 --json'
    assert_includes @calls[1][:shell], "--base #{BASE} --head #{HEAD}"
    assert_includes draw, 'bin/ci/reviewer_draw --size M --author autodev_bot --json'
    refute_includes draw, 'red'
  end

  test 'a red zone passes --red to the draw and writes MR::TestCoverage::Red' do
    @answers['mr_coverage'] = [0, { 'zone' => 'red' }]
    hand_off

    assert_includes @calls.find { |c| c[:shell].include?('reviewer_draw') }[:shell], '--size M --red --author'
    assert_includes labels, 'MR::TestCoverage::Red'
  end

  test 'the token reaches the container in a 0600 env file, never in argv' do # rubocop:disable Minitest/MultipleAssertions
    hand_off
    call = @calls.first

    refute(call[:args].any? { |a| a.include?('glpat-secret') })
    assert_includes call[:env], 'GITLAB_TOKEN=glpat-secret'
    assert_includes call[:env], 'GITLAB_HOST=gitlab.example.com'
    assert_equal 0o600, call[:mode]
    assert_equal 'danger-claude', call[:cmd]
    assert_equal "#{call[:args][1].split(':').first}:/autodev/handoff.env:ro", call[:args][1]
  end

  test 'the env file carries the locale and safe.directory the measurement needed, and is removed' do
    hand_off
    env = @calls.first[:env]

    assert_includes env, 'LANG=C.UTF-8'
    assert_includes env, "GIT_CONFIG_KEY_0=safe.directory\nGIT_CONFIG_VALUE_0=\\*"
    mount = @calls.first[:args][@calls.first[:args].index('-v') + 1].split(':').first

    refute_path_exists mount
  end

  test 'every declared argument is shell-escaped, so bash -c cannot reinterpret it' do
    config = PROJECT_CONFIG.merge('review_size_command' => ['bin/ci/mr_size', '$(touch /pwned)', '--json'])
    hand_off(config)

    assert_includes @calls.first[:shell], 'exec bin/ci/mr_size \$\(touch\ /pwned\) --json'
  end

  test 'the answer is the last stdout line that parses as a JSON object' do
    @answers['mr_size'] = [0, "{\"class\":\"S\"}\n{\"class\":\"M\"}\n[\"XL\"]\nmise WARN something\n"]
    hand_off

    assert_includes labels, 'MR::Size::M'
  end

  test 'a stdout holding no JSON object is not a measurement' do
    @answers['mr_size'] = [0, "[\"XS\"]\n"]
    hand_off

    assert_equal [:review_handoff_not_measured], entry_keys
  end

  test 'an element mixing text and a placeholder is substituted in place, a literal percent passes through' do
    argv = monitor.send(:handoff_argv, ['--mr=%{mr_iid}', '100%', '%{red_flag}'], { mr_iid: 17 }) # rubocop:disable Style/FormatStringToken

    assert_equal ['--mr=17', '100%'], argv
  end

  test 'the reviewer label must exist under its exact name, not as a prefix of another' do
    known = USERS.merge('alex_x' => [500, 'Alex Martin'])
    @client.define_singleton_method(:users) do |username:|
      id, name = known[username]
      id ? [{ 'id' => id, 'username' => username, 'name' => name }] : []
    end
    @answers['reviewer_draw'] = [0, { 'drawn' => %w[alex_x], 'postponed' => false }]
    hand_off

    assert_equal [:review_handoff_no_reviewer_unresolved], entry_keys
    refute(@client.edits.any? { |e| e[:add_labels].to_s.include?('MR::Reviewer::Alex') })
  end

  test 'a failing coverage still lets ready through: coverage is optional, size and the draw gate' do
    @answers['mr_coverage'] = [1, '']
    hand_off

    assert_includes labels, 'MR::ReadyForReview'
    assert_equal [{ 'id' => 194 }], @client.mr['reviewers']
  end

  test 'the work dir is removed whatever happens' do
    m = monitor
    m.define_singleton_method(:clone_and_checkout) do |dir, _branch|
      FileUtils.mkdir_p(dir)
      raise GitError, 'boom'
    end
    m.send(:hand_off_for_review, @issue)

    refute_path_exists '/tmp/autodev_review_handoff_group_app_42'
  end

  # -- Optional dimensions -----------------------------------------------------

  test 'an unmeasured zone leaves the coverage scope alone' do
    @client = FakeGitlab.new(labels: %w[MR::TestCoverage::High])
    @answers['mr_coverage'] = [0, { 'zone' => 'unmeasured' }]
    hand_off

    assert_includes labels, 'MR::TestCoverage::High'
    assert_includes labels, 'MR::ReadyForReview'
    assert_equal '—', @entries.first.last[:coverage]
  end

  test 'a coverage script that fails omits the label and does not stop the handoff' do
    @answers['mr_coverage'] = [1, '']
    hand_off

    assert_empty labels.grep(/TestCoverage/)
    assert_equal [:review_handoff_ready], entry_keys
  end

  test 'an unknown zone or class is a failed measurement, never a label' do
    @answers['mr_coverage'] = [0, { 'zone' => 'Medium' }]
    hand_off

    assert_empty labels.grep(/TestCoverage/)

    @client = FakeGitlab.new
    @entries.clear
    @answers['mr_size'] = [0, { 'class' => 'XXXL' }]
    hand_off

    assert_empty @client.edits
    assert_equal [:review_handoff_not_measured], entry_keys
  end

  test 'remove-then-add: a stale size and coverage are replaced, not stacked' do
    @client = FakeGitlab.new(labels: %w[MR::Size::XS MR::TestCoverage::Low Backend])
    hand_off

    assert_equal %w[Backend MR::Size::M MR::TestCoverage::Standard], labels.grep_v(/Reviewer|Ready/).sort
  end

  test 'a project declaring no draw gets size, coverage and ready, and no reviewer' do # rubocop:disable Minitest/MultipleAssertions
    hand_off(PROJECT_CONFIG.except('reviewer_draw_command'))

    assert_empty @client.mr['reviewers']
    assert_includes labels, 'MR::ReadyForReview'
    assert_equal [:review_handoff_ready_no_draw], entry_keys
    refute(@calls.any? { |c| c[:shell].include?('reviewer_draw') })
  end

  test 'a project declaring nothing gets nothing: no clone, no container, no write, no entry' do
    hand_off(PROJECT_CONFIG.except('review_size_command', 'review_coverage_command', 'reviewer_draw_command'))

    assert_empty @calls
    assert_empty @client.edits
    assert_empty @entries
  end

  # -- A reviewer already there -------------------------------------------------

  test 'a reviewer already on the merge request is kept: no draw, nothing reviewer-shaped written' do # rubocop:disable Minitest/MultipleAssertions
    @client = FakeGitlab.new(reviewers: [{ 'id' => 363 }], labels: %w[MR::Reviewer::David])
    hand_off

    refute(@calls.any? { |c| c[:shell].include?('reviewer_draw') })
    assert_equal [{ 'id' => 363 }], @client.mr['reviewers']
    refute(@client.edits.any? { |e| e.key?(:reviewer_ids) || e.key?(:assignee_id) })
    assert_includes labels, 'MR::Reviewer::David'
    assert_equal [:review_handoff_ready_reviewer_kept], entry_keys
  end

  test 'a reviewer label alone (Team, posted by a human) is enough to keep the review as it is' do
    @client = FakeGitlab.new(labels: %w[MR::Reviewer::Team])
    hand_off

    assert_includes labels, 'MR::Reviewer::Team'
    assert_equal [:review_handoff_ready_reviewer_kept], entry_keys
  end

  test 'a second delivery converges: same labels, no new draw, no duplicate write of ready' do # rubocop:disable Minitest/MultipleAssertions
    hand_off
    first = labels.sort
    edits = @client.edits.size
    hand_off

    assert_equal first, labels.sort
    assert_equal(2, @calls.count { |c| c[:shell].include?('mr_size') })
    assert_equal(1, @calls.count { |c| c[:shell].include?('reviewer_draw') })
    assert_equal edits, @client.edits.size
  end

  # -- No reviewer, never a guessed one -----------------------------------------

  test 'draw exit 2: no reviewer, no ready, size and coverage written, the note says the absence check failed' do # rubocop:disable Minitest/MultipleAssertions
    @answers['reviewer_draw'] = [2, '']
    hand_off

    assert_empty @client.mr['reviewers']
    assert_empty @client.mr['assignees']
    refute_includes labels, 'MR::ReadyForReview'
    assert_includes labels, 'MR::Size::M'
    assert_equal [:review_handoff_no_reviewer_absences], entry_keys
    assert_equal 'exit 2', @entries.first.last[:reason]
  end

  test "a script's stderr never reaches the ticket, only its exit code; the log keeps the stderr" do
    @answers['reviewer_draw'] = [2, '']
    m = monitor
    m.send(:hand_off_for_review, @issue)

    refute(@entries.flatten.map(&:to_s).any? { |v| v.include?('stderr line') })
    assert(m.instance_variable_get(:@logger).messages.any? { |msg| msg.include?('reviewer_draw: stderr line') })
  end

  test 'a postponed draw, a failed draw and an unreadable draw write no reviewer and no ready' do
    { [0, { 'drawn' => [], 'postponed' => true }] => :review_handoff_no_reviewer_postponed,
      [1, ''] => :review_handoff_no_reviewer_draw_failed,
      [0, { 'drawn' => [] }] => :review_handoff_no_reviewer_draw_failed }.each do |answer, key|
      @client = FakeGitlab.new
      @entries.clear
      @answers['reviewer_draw'] = answer
      hand_off

      assert_equal [key], entry_keys, answer.inspect
      assert_empty @client.mr['reviewers']
      refute_includes labels, 'MR::ReadyForReview'
    end
  end

  test 'a drawn username GitLab does not know, or whose label does not exist, writes no reviewer' do
    @answers['reviewer_draw'] = [0, { 'drawn' => %w[bourea_d], 'postponed' => false }]
    hand_off

    assert_empty @client.mr['reviewers']
    assert_empty labels.grep(/Reviewer/)
    assert_equal [[:review_handoff_no_reviewer_unresolved,
                   { username: 'bourea_d', labels: 'MR::Size::M, MR::TestCoverage::Standard',
                     ready: 'MR::ReadyForReview non pose' }]], @entries
  end

  test 'a size that cannot be measured writes nothing at all and runs nothing else' do
    @answers['mr_size'] = [1, '']
    hand_off

    assert_empty @client.edits
    assert_equal 1, @calls.size
    assert_equal [:review_handoff_not_measured], entry_keys
  end

  test 'a merge request without diff_refs is not measured: no clone, no container' do
    @client = FakeGitlab.new(diff_refs: nil)
    hand_off

    assert_empty @calls
    assert_equal [:review_handoff_not_measured], entry_keys
  end

  # -- Read back ----------------------------------------------------------------

  test 'a reviewer GitLab silently dropped is reported and ready is not posted' do
    @client.drop_reviewers = true
    hand_off

    refute_includes labels, 'MR::ReadyForReview'
    assert_equal [:review_handoff_not_landed], entry_keys
    assert_includes @entries.first.last[:what], 'relecteur alexan_a'
  end

  test 'a dropped reviewer leaves no reviewer label, so the next delivery draws again instead of keeping nobody' do # rubocop:disable Minitest/MultipleAssertions
    @client.drop_reviewers = true
    hand_off

    assert_empty labels.grep(/Reviewer/)

    @client.drop_reviewers = false
    @entries.clear
    hand_off

    assert_equal [:review_handoff_ready], entry_keys
    assert_equal [{ 'id' => 194 }], @client.mr['reviewers']
    assert_equal(2, @calls.count { |c| c[:shell].include?('reviewer_draw') })
  end

  # Integration review of the alpha-57 lot: on a merge request already carrying
  # Ready the entry ended "MR::ReadyForReview not." while the label stayed, and
  # listed as written labels that were already there.
  test 'no reviewer on a merge request already ready: only added labels are listed, ready is said left as is' do # rubocop:disable Minitest/MultipleAssertions
    @client = FakeGitlab.new(labels: %w[MR::ReadyForReview MR::Size::M])
    @answers['reviewer_draw'] = [0, { 'drawn' => [], 'postponed' => true }]
    hand_off

    assert_includes labels, 'MR::ReadyForReview'
    assert_equal [:review_handoff_no_reviewer_postponed], entry_keys
    assert_equal 'MR::TestCoverage::Standard', @entries.first.last[:labels]
    assert_match(/MR::ReadyForReview deja present, laisse tel quel/, rendered(:fr))
    refute_match(/pas MR::ReadyForReview/, rendered(:fr))
  end

  test 'no reviewer and nothing added: the entry says no label was added' do
    @client = FakeGitlab.new(labels: %w[MR::Size::M MR::TestCoverage::Standard])
    @answers['reviewer_draw'] = [1, '']
    hand_off

    assert_equal [:review_handoff_no_reviewer_draw_failed], entry_keys
    assert_match(/Labels ajoutes : aucun ; MR::ReadyForReview non pose\./, rendered(:fr))
  end

  test 'a note without reviewer names only the labels actually written' do
    @answers['mr_coverage'] = [1, '']
    @answers['reviewer_draw'] = [2, '']
    hand_off

    assert_equal 'MR::Size::M', @entries.first.last[:labels]
  end

  test 'each script is bounded well under the one-hour concurrency semaphore' do
    seen = []
    test = self
    m = monitor
    m.define_singleton_method(:run_with_timeout) do |cmd, args, **opts|
      seen << opts[:timeout]
      test.container(cmd, args)
    end
    m.send(:hand_off_for_review, @issue)

    assert_equal [600, 600, 600], seen
  end

  test 'a label GitLab did not keep is reported and ready is not posted' do
    @client.drop_labels = %w[MR::Size::M]
    hand_off

    refute_includes labels, 'MR::ReadyForReview'
    assert_equal [:review_handoff_not_landed], entry_keys
    assert_includes @entries.first.last[:what], 'MR::Size::M'
  end

  test 'ready itself is read back' do
    @client.drop_labels = %w[MR::ReadyForReview]
    hand_off

    assert_equal [:review_handoff_not_landed], entry_keys
  end

  # Integration review of the alpha-57 lot: the entry said "MR::ReadyForReview
  # not posted" on a merge request that carried it.
  test 'a read-back of ready that GitLab does not answer says not confirmed, never not posted' do # rubocop:disable Minitest/MultipleAssertions
    read_back_times_out_after('MR::ReadyForReview')
    hand_off

    assert_includes labels, 'MR::ReadyForReview'
    assert_equal [:review_handoff_ready_not_confirmed], entry_keys
    assert_match(/non confirme/, rendered(:fr))
    assert_match(/not confirmed/, rendered(:en))
    refute_match(/non pose/, rendered(:fr))
    refute_match(/not posted/, rendered(:en))
  end

  test 'a read-back of an earlier write that GitLab does not answer says not confirmed, and ready was not sent' do # rubocop:disable Minitest/MultipleAssertions
    @issue.update!(locale: 'en')
    read_back_times_out_after('MR::Size::M')
    hand_off

    refute_includes labels, 'MR::ReadyForReview'
    assert_equal [:review_handoff_not_confirmed], entry_keys
    assert_includes @entries.first.last[:what], 'MR::Size::M'
    assert_match(/not confirmed/, rendered(:en))
    assert_match(/MR::ReadyForReview not posted/, rendered(:en))
  end

  test 'an assignee GitLab did not keep is reported and ready is not posted' do
    @client.drop_assignees = true
    hand_off

    refute_includes labels, 'MR::ReadyForReview'
    assert_equal [[:review_handoff_not_landed, { what: 'assignee a bernar_a', ready: 'MR::ReadyForReview non pose' }]],
                 @entries
  end

  test 'a stale label GitLab refused to remove is reported and ready is not posted' do
    @client = FakeGitlab.new(labels: %w[MR::Size::XS])
    @client.keep_labels = %w[MR::Size::XS]
    hand_off

    refute_includes labels, 'MR::ReadyForReview'
    assert_equal [[:review_handoff_not_landed, { what: '-MR::Size::XS', ready: 'MR::ReadyForReview non pose' }]],
                 @entries
  end

  test 'a draw answering three names designates the first two only' do
    @answers['reviewer_draw'] = [0, { 'drawn' => %w[alexan_a bernar_a billau_l], 'postponed' => false }]
    hand_off

    assert_equal [{ 'id' => 194 }], @client.mr['reviewers']
    assert_equal [{ 'id' => 337 }], @client.mr['assignees']
    refute_includes labels, 'MR::Reviewer::Lucas'
  end

  test 'an empty size command at runtime is no declaration' do
    hand_off(PROJECT_CONFIG.merge('review_size_command' => []))

    assert_empty @calls
    assert_empty @entries
  end

  test 'a merge request whose head_sha is missing is not measured' do
    @client = FakeGitlab.new(diff_refs: { 'base_sha' => BASE, 'head_sha' => nil })
    hand_off

    assert_empty @calls
    assert_equal [:review_handoff_not_measured], entry_keys
  end

  test 'both diff ends present: no fetch, so a full clone is not made shallow' do
    fetched = fetch_commands(present: [BASE, HEAD])

    assert_empty fetched
  end

  test 'one diff end missing: only that one is fetched' do
    fetched = fetch_commands(present: [HEAD])

    assert_equal [%W[git fetch --depth 1 origin #{BASE}]], fetched
  end

  test 'a GitLab on a custom port reaches the scripts with its port' do
    m = monitor
    m.instance_variable_set(:@gitlab_url, 'https://gitlab.example.com:8443')
    m.send(:hand_off_for_review, @issue)

    assert_includes @calls.first[:env], 'GITLAB_HOST=gitlab.example.com:8443'
  end

  # Phase-10 review of the alpha-57 lot: "reviewer <user>" / "assignee <user>"
  # were English words inside a French note.
  test 'the people a read-back names are in the issue locale' do
    @client.drop_reviewers = true
    @client.drop_assignees = true
    hand_off

    assert_match(/\(relecteur alexan_a, assignee a bernar_a\)/, rendered(:fr))
    refute_match(/reviewer alexan_a/, rendered(:fr))

    @issue.update!(locale: 'en')
    @client = FakeGitlab.new
    @client.drop_reviewers = true
    @entries.clear
    hand_off

    assert_equal 'reviewer alexan_a', @entries.first.last[:what]
  end

  test 'a read-back that GitLab does not answer names the people in the issue locale' do
    read_back_times_out_after('MR::Size::M')
    hand_off

    assert_match(/relecteur alexan_a, assignee a bernar_a non confirme/, rendered(:fr))
  end

  # Phase-10 review of the alpha-57 lot: these three entries ended "not posted"
  # on a merge request that carried Ready all along — `post_ready` leaves it.
  { 'a write that did not read back' => -> { @client.drop_labels = %w[MR::Size::M] },
    'a read-back GitLab did not answer' => -> { read_back_times_out_after('MR::Size::M') },
    'an interrupted handoff' => -> { @client.define_singleton_method(:edit_merge_request) { |*| raise EOFError } } }
    .each do |what, prepare|
    test "#{what} on a merge request already ready says ready was left as is" do
      { fr: /MR::ReadyForReview deja present, laisse tel quel/,
        en: /MR::ReadyForReview already present, left as is/ }.each do |locale, said|
        @issue.update!(locale: locale.to_s)
        @client = FakeGitlab.new(labels: %w[MR::ReadyForReview])
        @entries.clear
        instance_exec(&prepare)
        hand_off

        assert_match(said, rendered(locale))
      end
    end
  end

  test 'an interrupted handoff on a merge request without ready still says not posted' do
    @client.define_singleton_method(:merge_request) { |*| raise Net::OpenTimeout, 'cut' }
    hand_off

    assert_match(/MR::ReadyForReview non pose/, rendered(:fr))
  end

  # -- Never raises -------------------------------------------------------------

  test 'a GitLab outage or a clone failure ends in one entry and never escapes' do
    @client.define_singleton_method(:merge_request) { |*| raise Net::OpenTimeout, 'cut' }
    hand_off

    assert_equal [:review_handoff_failed], entry_keys

    @client = FakeGitlab.new
    @entries.clear
    m = monitor
    m.define_singleton_method(:clone_and_checkout) { |*| raise GitError, 'https://oauth2:glpat-secret@x failed' }
    m.send(:hand_off_for_review, @issue)

    assert_equal [:review_handoff_failed], entry_keys
    refute_includes @entries.first.last[:reason], 'glpat-secret'
  end

  test 'the handoff changes neither the row nor the ticket' do
    before = @issue.reload.attributes.except('updated_at')
    hand_off

    assert_equal before, @issue.reload.attributes.except('updated_at')
  end

  # -- The entries render in both locales with the variables the code passes ---

  test 'every entry the handoff writes renders in fr and en with no variable missing' do
    scenarios = [-> {}, -> { @answers['reviewer_draw'] = [2, ''] }, -> { @answers['mr_size'] = [1, ''] },
                 -> { @client.drop_reviewers = true },
                 -> { @client.define_singleton_method(:merge_request) { |*| raise Net::OpenTimeout } }]
    scenarios.each do |prepare|
      @client = FakeGitlab.new
      prepare.call
      hand_off
    end

    @entries.each do |key, vars|
      %i[fr en].each do |locale|
        text = I18n.t(:"activity_#{key}", locale: locale, **vars, raise: true)

        refute_match(/%\{/, text, "#{key} (#{locale}) left a placeholder")
      end
    end
  end

  test 'every review_handoff key the code names is an outcome, and every outcome exists in fr and en' do
    files = Dir[Rails.root.join('lib/autodev/pipeline_monitor/review_handoff*.rb')]
    named = files.flat_map { |f| File.read(f).scan(/:(review_handoff_\w+)/).flatten }.map(&:to_sym).uniq

    assert_equal PipelineMonitor::ReviewHandoffVocabulary::OUTCOMES.sort, named.sort
    PipelineMonitor::ReviewHandoffVocabulary::OUTCOMES.each do |key|
      %i[fr en].each { |locale| assert I18n.exists?(:"activity_#{key}", locale), "#{key} missing in #{locale}" }
    end
  end

  # -- Wired at the delivery, and only there -----------------------------------

  test 'finalize_green_done hands off last, after the handback and the stamp' do
    m = monitor
    order = []
    %i[apply_label_done hand_ticket_back notify_localized].each do |name|
      m.define_singleton_method(name) { |*, **| order << name }
    end
    m.define_singleton_method(:hand_off_for_review) { |_issue| order << :hand_off_for_review }
    m.send(:finalize_green_done, @issue, [])

    assert_equal %i[apply_label_done hand_ticket_back notify_localized hand_off_for_review], order
    assert_predicate @issue.reload.finished_at, :present?
  end

  test 'finished_at is already stamped when the handoff starts' do
    m = monitor
    %i[apply_label_done hand_ticket_back notify_localized].each do |name|
      m.define_singleton_method(name) do |*, **|
        nil
      end
    end
    stamped = nil
    m.define_singleton_method(:hand_off_for_review) { |issue| stamped = Issue.find(issue.id).finished_at }
    m.send(:finalize_green_done, @issue, [])

    assert_predicate stamped, :present?
  end

  test 'no other delivery path hands off' do
    callers = Dir[Rails.root.join('{lib,app}/**/*.rb')].select { |f| File.read(f).include?('hand_off_for_review(') }
    callers = callers.map { |f| f.delete_prefix("#{Rails.root}/") }.sort

    assert_equal %w[lib/autodev/pipeline_monitor.rb lib/autodev/pipeline_monitor/review_handoff.rb], callers
  end
end
