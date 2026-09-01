# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'openssl'
require 'socket'
require 'timeout'
require 'autodev/pipeline_monitor'

# Autodev #62, third round — a connection that broke is not an HTTP response.
#
# `GitlabHelpers.answer` is the single conversion point from "GitLab did not
# answer" to `ApiUnavailableError`, and it only knew one shape of not answering:
# `Gitlab::Error::ResponseError`, i.e. GitLab answered with a status. A VPN hiccup
# answers nothing at all — `Net::ReadTimeout`, `Errno::ECONNRESET`,
# `OpenSSL::SSL::SSLError`, a DNS failure — and none of those is a
# `ResponseError`.
#
# What that cost, on the two paths this round audited:
#
#   * `SkillReviewer#run_skill_review` sorts its outcomes with `rescue
#     ApiUnavailableError; raise` above `rescue StandardError => e; raise
#     ImplementationError`, and the comment above that split says in as many words
#     that it exists so an outage is not read as a review failure. The guard only
#     covered HTTP: five successive hiccups produced `review_failures_exhausted`,
#     `label_attention` and the ticket handed back to its author — the very defect
#     Autodev #88 is cleaning up after, reproduced by another route inside the
#     same release;
#   * `ReviewSkillSource.locate`, called bare at the top of
#     `prepare_review_clone`, left the row parked in `reviewing` — a status
#     `dispatch_pipelines` does not select — recoverable only by `DormantAudit`
#     two hours later and at the price of one of its three attempts.
#
# So the conversion is widened at the one place, and the control below is the half
# that matters as much: a *programming* error is not a transport failure and must
# keep travelling as itself. Swallowing `NoMethodError` into "GitLab is down"
# would be the same class of lie in the other direction.
class ABrokenConnectionIsNotAVerdictTest < Minitest::Test
  include DatabaseTestHelper

  SKILL = 'mr-review'
  CANONICAL = ".claude/skills/#{SKILL}/SKILL.md".freeze
  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'

  # Every way a request can die without a status line, as the stack raises them:
  # `httparty` → `net/http` → `openssl` → the socket, with nothing in between to
  # translate them.
  TRANSPORT_FAILURES = {
    'a read that never completed' => -> { raise Net::ReadTimeout },
    'a connection that never opened' => -> { raise Net::OpenTimeout },
    'a peer that hung up' => -> { raise Errno::ECONNRESET, 'Connection reset by peer' },
    'a route that disappeared' => -> { raise Errno::EHOSTUNREACH, 'No route to host' },
    'a refused port' => -> { raise Errno::ECONNREFUSED, 'Connection refused' },
    'a name that stopped resolving' => -> { raise SocketError, 'getaddrinfo: nodename nor servname' },
    'a TLS handshake that failed' => -> { raise OpenSSL::SSL::SSLError, 'unexpected eof while reading' },
    'a response that stopped mid-body' => -> { raise EOFError, 'end of file reached' }
  }.freeze

  # The control population: none of these is GitLab's fault, and each one is a bug
  # in this repository that has to reach a stack trace.
  PROGRAMMING_FAILURES = {
    'a method that does not exist' => -> { raise NoMethodError, "undefined method 'iid' for nil" },
    'the wrong number of arguments' => -> { raise ArgumentError, 'wrong number of arguments' },
    'a constant that is not loaded' => -> { raise NameError, 'uninitialized constant Foo' },
    'a type that cannot be coerced' => -> { raise TypeError, 'no implicit conversion' }
  }.freeze

  def setup = setup_database

  # --- 1. the conversion point --------------------------------------------

  def test_every_transport_failure_leaves_as_an_unavailable_api
    TRANSPORT_FAILURES.each do |described, raiser|
      error = assert_raises(ApiUnavailableError, "#{described} was not converted") do
        GitlabHelpers.answer(:pipeline_jobs) { raiser.call }
      end

      assert_equal :pipeline_jobs, error.what, "#{described} lost the name of the read"
    end
  end

  # The cause survives, because that is what a log line needs in order to say
  # *which* outage this was — the same property the HTTP case has had since #62.
  def test_the_underlying_failure_travels_as_the_cause
    error = assert_raises(ApiUnavailableError) { GitlabHelpers.answer(:merge_request) { raise Net::ReadTimeout } }

    assert_kind_of Net::ReadTimeout, error.cause
  end

  def test_a_programming_error_is_not_an_outage
    PROGRAMMING_FAILURES.each do |described, raiser|
      raised = assert_raises(StandardError) { GitlabHelpers.answer(:pipeline_jobs) { raiser.call } }

      refute_kind_of ApiUnavailableError, raised, "#{described} was swallowed as an outage"
    end
  end

  # Stated as a property rather than as the list above, so a class added to the
  # conversion tomorrow cannot quietly be a `StandardError` catch-all.
  def test_the_conversion_is_not_a_catch_all
    assert_raises(NoMethodError) { GitlabHelpers.answer(:whatever) { nil.iid } }
  end

  # --- 2. the review path, end to end -------------------------------------

  # `locate` is the first statement of `prepare_review_clone`, called bare so that
  # a read GitLab could not answer aborts before a clone is paid for. A transport
  # failure there used to reach `check`'s `rescue StandardError`, which logs and
  # returns — leaving the row in `reviewing`.
  def test_a_broken_connection_while_locating_the_skill_returns_the_row_to_the_watch
    row = reviewing_issue

    monitor(failing: :get_file).then do |mon|
      assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
    end

    assert_equal ['checking_pipeline', 0, 0],
                 [row.reload.status, row.review_count, row.review_failure_count]
  end

  # The gravest consequence, and the reason this is a `GRAVE` and not a tidy-up:
  # five polls behind a flapping VPN spent the whole review budget and handed the
  # ticket back to its author under `review_failures_exhausted`.
  def test_a_broken_connection_never_spends_the_review_budget
    row = reviewing_issue

    PipelineMonitor::Reviewer::REVIEW_FAILURE_THRESHOLD.times do
      mon = monitor(failing: :file_contents)
      assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
      row.reload
      row.pipeline_green! if row.status == 'checking_pipeline'
    end

    assert_equal 0, row.reload.review_failure_count
    assert_nil row.attention_reason
  end

  private

  def reviewing_issue
    Issue.create!(project_path: PROJECT_PATH, issue_iid: 4242, mr_iid: 7,
                  mr_url: 'https://gitlab.example/mr/7', issue_author_id: 42,
                  branch_name: 'autodev/issue-4242', status: 'reviewing',
                  review_count: 0, review_failure_count: 0, locale: 'fr')
  end

  # The one read that fails is `failing:`; every other one answers, so the failure
  # under test is the only thing that could have ended the review.
  class FakeGitlab
    Blob = Struct.new(:type, :path)
    Repo = Struct.new(:default_branch)
    Note = Struct.new(:id, :body)
    GlIssue = Struct.new(:labels, :id)

    def initialize(files:, failing:, raiser:)
      @files = files
      @failing = failing
      @raiser = raiser
    end

    def project(_path)
      guard(:project)
      Repo.new('master')
    end

    def merge_request(_path, iid)
      guard(:merge_request)
      Struct.new(:iid, :state, :target_branch).new(iid, 'opened', 'master')
    end

    def get_file(_path, file, _ref)
      guard(:get_file)
      raise not_found unless @files.key?(file)

      Struct.new(:file_path).new(file)
    end

    def commit(_path, _ref)
      guard(:commit)
      Struct.new(:id).new('deadbeef')
    end

    def tree(_path, options)
      guard(:tree)
      Gitlab::PaginatedResponse.new(@files.keys.select { |f| f.start_with?("#{options[:path]}/") }
                                          .map { |file| Blob.new('blob', file) })
    end

    def file_contents(_path, file, _ref)
      guard(:file_contents)
      @files.fetch(file)
    end

    def issue(_path, _iid) = GlIssue.new(labels: ['Doing'], id: 1)
    def user = GlIssue.new(labels: [], id: 999)
    def edit_issue(_path, _iid, **_attrs) = GlIssue.new(labels: [], id: 1)
    def create_issue_note(_path, _iid, body) = Note.new(1, body)
    def issue_note(_path, _iid, note_id) = Note.new(note_id, '')
    def edit_issue_note(_path, _iid, _note_id, body) = Note.new(1, body)

    private

    def guard(kind)
      @raiser.call if @failing == kind
    end

    def not_found
      request = Struct.new(:base_uri, :path).new('https://gitlab.example', '/api/v4')
      Gitlab::Error::NotFound.new(Struct.new(:code, :parsed_response, :request).new(404, {}, request))
    end
  end

  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*, **| nil } }
  end

  def monitor(failing:, raiser: -> { raise Errno::ECONNRESET, 'Connection reset by peer' })
    client = FakeGitlab.new(files: { CANONICAL => "# #{SKILL}" }, failing: failing, raiser: raiser)
    PipelineMonitor.allocate.tap do |mon|
      mon.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: { 'path' => PROJECT_PATH, 'target_branch' => 'master',
                                               'review_skill' => SKILL },
                             logger: NullLogger.new, token: 'tok')
      stub_everything_but_the_reads!(mon)
    end
  end

  def stub_everything_but_the_reads!(mon)
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:mr_review_timeout) { 600 }
    mon.define_singleton_method(:clone_and_checkout) { |dir, _b| FileUtils.mkdir_p(dir) }
    mon.define_singleton_method(:danger_claude_prompt) { |*, **| 'ok' }
    mon.define_singleton_method(:publish_review) { |*| { posted: 0, demoted: 0 } }
  end
end
