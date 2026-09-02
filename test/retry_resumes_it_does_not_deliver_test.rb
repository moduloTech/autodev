# frozen_string_literal: true

require_relative 'rails_helper'

# Autodev #100 — a retry resumes the work; it does not deliver it.
#
# `perform_retry_errored` restored a label chosen on whether the request had a
# merge request: with one it posed `label_done`, without one `label_doing`. Both
# destinations are **working** states — `retry_pipeline!` → `checking_pipeline`,
# `retry_processing!` → `pending` — so the first announced the work as finished
# while autodev carried on.
#
# On powerpanne that end label is `Development::Awaiting Feature Review`, the
# PM's review column. Measured on request 15205 on 02/09/2026: `error` →
# `checking_pipeline` at 00:50:03, and at 00:50:04 autodev added
# `Development::Awaiting Feature Review` and removed `Development::Doing`. The
# ticket sat in the review column for **ten hours** while rounds 5 to 18 of
# discussion fixing ran underneath it.
#
# ## The fork was right once, and the rename moved the ground under it
#
# It was introduced by "label-driven workflow with resume from over", whose own
# commit message lists five labels:
#
#     label_mr:   set after MR creation, enables discussion monitoring
#     label_done: set by human reviewer to signal completion
#
# `has_mr ? apply_label_mr : apply_label_doing` was then exactly "restore the
# label that matches where this row is going", and it was correct. The config
# was later collapsed to three labels and `label_mr` was **renamed**
# `label_done` — taking over the meaning that had belonged to a different label
# — while the retry kept calling the same method name. Nothing about the retry
# changed; the word underneath it did.
#
# Which is why both branches now pose the working label and the fork is gone:
# there is no question left for it to answer.
class RetryResumesItDoesNotDeliverTest < ActiveSupport::TestCase
  PROJECT_PATH = 'group/foo'
  ISSUE_IID = 42

  # Every call site of the end label, and the delivery each one makes. Derived
  # against the tree by the last test in this file, in the shape
  # `test/api_failure_is_not_a_verdict_test.rb` uses: it proves every call site
  # is **declared**, never that a declaration is true. What a reader gets from it
  # is that a new one cannot appear without somebody writing down what it
  # delivers — which is the sentence `perform_retry_errored` could not have
  # written.
  DELIVERIES = {
    'lib/autodev/pipeline_monitor.rb' => {
      'finalize_green_done' => 'green pipeline, reviewed, no unresolved thread → done'
    },
    'lib/autodev/pipeline_monitor/mr_state_checker.rb' => {
      'finish_merged_mr' => 'GitLab says the merge request is merged → done'
    },
    'lib/autodev/poll_router/resume_handler.rb' => {
      'skip_reentry_already_merged' => 'a todo label reposed on work that is already merged; stays done'
    },
    'lib/autodev/issue_processor/question_handler.rb' => {
      'finalize_question' => 'the investigation is answered on the ticket → done'
    }
  }.freeze

  setup do
    @config = {
      'gitlab_url' => 'https://gitlab.example.com', 'gitlab_token' => 'glpat-xxx',
      'projects' => [{ 'path' => PROJECT_PATH, 'labels_todo' => ['To do'],
                       'label_doing' => 'Development::Doing',
                       'label_done' => 'Development::Awaiting Feature Review' }]
    }
    @issue = fake_issue
    @posed = []
  end

  # The defect. `checking_pipeline` is where the row lands, and it is a state in
  # which autodev is still working.
  test 'a retry on a request that carries a merge request poses the working label' do
    @issue.mr_iid = 17

    run_retry

    assert_equal %i[doing], @posed
  end

  # The control: the branch that was already right must stay right, or the fix
  # would have moved the defect rather than removed it.
  test 'a retry on a request with no merge request poses the working label too' do
    run_retry

    assert_equal %i[doing], @posed
  end

  # And the transition itself is untouched — this ticket is about the label, not
  # about where the retry goes.
  test 'a retry still resumes the pipeline watch when a merge request exists' do
    @issue.mr_iid = 17

    run_retry

    assert_includes @issue.fired, :retry_pipeline!
  end

  test 'the end label has no caller whose destination is not a declared delivery' do
    assert_equal DELIVERIES, end_label_call_sites
  end

  private

  def run_retry
    @issue.status = 'error'
    Config.stub(:load, @config) do
      Issue.stub(:where, ->(**_) { fake_dataset(@issue) }) { perform_with_stubs }
    end
  end

  def perform_with_stubs
    GitlabHelpers.stub(:build_gitlab_client, Object.new) do
      ActivityLogger.stub(:post, true) do
        MrFixer.stub(:new, label_recorder) { IssueProcessJob.new.perform(PROJECT_PATH, ISSUE_IID, :retry_errored) }
      end
    end
  end

  # Which of the two labels was asked for, and nothing else: the question is the
  # choice, not the GitLab call underneath it.
  def label_recorder
    posed = @posed
    Object.new.tap do |rec|
      rec.define_singleton_method(:apply_label_doing) { |_iid| posed << :doing }
      rec.define_singleton_method(:apply_label_done) { |_iid| posed << :done }
    end
  end

  def fake_issue
    Struct.new(:issue_iid, :mr_iid, :status, :retry_count, :fired) do
      def update(**) = self
      def retry_processing! = fired << :retry_processing!
      def retry_pipeline! = fired << :retry_pipeline!
    end.new(ISSUE_IID, nil, 'error', 0, [])
  end

  def fake_dataset(row)
    Struct.new(:row) do
      def first = row
    end.new(row)
  end

  # A line calling the end label, attributed to the `def` above it. The
  # definition itself and the `public :apply_label_done` re-export are not calls
  # and are skipped by requiring the parenthesis.
  def end_label_call_sites
    Dir.glob(Rails.root.join('{lib,app}/**/*.rb')).each_with_object({}) do |path, found|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      calls_in(File.readlines(path)).each do |method|
        (found[relative] ||= {})[method] = DELIVERIES.dig(relative, method) || 'UNDECLARED'
      end
    end
  end

  def calls_in(lines)
    method = nil
    lines.each_with_object([]) do |line, found|
      method = ::Regexp.last_match(1) if line =~ /^\s*def\s+([a-z_][\w?!]*)/
      found << method if line.include?('apply_label_done(') && line !~ /^\s*(#|def )/
    end
  end
end
