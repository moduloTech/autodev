# frozen_string_literal: true

module Autodev
  # Inspects and (re)triggers the `deploy_review` CI job that deploys an
  # issue's review environment.
  #
  # The job is matched by *exact* name (`deploy_review`) in the pipeline that
  # represents the issue's work — the **MR head pipeline** when the issue has an
  # MR (same source `PipelineMonitor#check` watches; it's also what catches
  # detached/MR pipelines that a `ref=branch` query would miss), otherwise the
  # latest branch pipeline. A still-manual job (never run) is **played**; a
  # finished job is **retried**. Every GitLab failure degrades to an `:error`
  # outcome so the dashboard renders a disabled button rather than a 500 — the
  # action is best-effort, never load-bearing.
  class DeployReview
    JOB_NAME = 'deploy_review'

    # GitLab job statuses bucketed by what we can actually do with them. A
    # still-manual job is *played*; a finished one is *retried*. Anything in
    # between can't be acted on — the GitLab API would reject play/retry — so we
    # disable the button up front with an honest reason rather than letting the
    # click 4xx into an error flash. BLOCKED = waiting on an upstream stage
    # (often a failure); IN_FLIGHT = already running. Statuses outside every
    # bucket (e.g. a future GitLab status) fall through to :unknown — disabled
    # with a neutral message, never the misleading "already running".
    PLAYABLE = %w[manual].freeze
    RETRYABLE = %w[success failed canceled].freeze
    BLOCKED = %w[created skipped].freeze
    IN_FLIGHT = %w[running pending preparing waiting_for_resource scheduled].freeze
    private_constant :PLAYABLE, :RETRYABLE, :BLOCKED, :IN_FLIGHT

    # i18n key explaining each non-actionable state — shared by the lazy frame
    # (disabled-button caption) and the POST flash so both speak the same
    # language instead of the POST collapsing everything to one generic line.
    REASON_KEYS = {
      no_branch: :web_issue_deploy_review_no_branch,
      no_pipeline: :web_issue_deploy_review_no_pipeline,
      no_job: :web_issue_deploy_review_no_job,
      blocked: :web_issue_deploy_review_blocked,
      running: :web_issue_deploy_review_running,
      unknown: :web_issue_deploy_review_unknown,
      error: :web_issue_deploy_review_error
    }.freeze

    def self.reason_key(state)
      REASON_KEYS.fetch(state, :web_issue_deploy_review_error)
    end

    # state: :available / :triggered on the happy paths; :blocked (upstream not
    # done), :running (in flight) or :unknown (unrecognised status) when the job
    # exists but isn't actionable; otherwise :no_branch, :no_pipeline, :no_job,
    # :error. `action` is :play or :retry (set on :available and :triggered);
    # `message` carries the raw GitLab error on :error (logged, never shown).
    Outcome = Struct.new(:state, :action, :message)

    def initialize(issue, config: nil, client: nil)
      @issue = issue
      @config = config || (::Web.config || {})
      @client = client
    end

    # Read-only probe used by the lazy turbo-frame: is the deploy_review job
    # present on the branch's latest pipeline, and is it in a state we can act
    # on? Returns an :available outcome (carrying :play/:retry) when actionable,
    # else :blocked / :running / :no_* / :error.
    def availability
      job = locate_job
      return job if job.is_a?(Outcome) # a failure outcome short-circuits

      classify(job)
    rescue StandardError => e
      Outcome.new(state: :error, message: e.message)
    end

    # Play (manual) or retry (finished) the deploy_review job. Non-actionable
    # states (:blocked / :running) are returned as-is without touching GitLab.
    def trigger!
      job = locate_job
      return job if job.is_a?(Outcome)

      outcome = classify(job)
      return outcome unless outcome.state == :available

      play_or_retry(job, outcome.action)
      Outcome.new(state: :triggered, action: outcome.action)
    rescue StandardError => e
      Outcome.new(state: :error, message: e.message)
    end

    private

    # Returns the GitLab job object on success, or a failure Outcome when the
    # pipeline / job can't be found.
    def locate_job
      return Outcome.new(state: :no_branch) if mr_iid.nil? && branch.to_s.empty?

      pipeline = relevant_pipeline
      return Outcome.new(state: :no_pipeline) unless pipeline

      job = find_deploy_review_job(pipeline)
      job || Outcome.new(state: :no_job)
    end

    # The MR head pipeline when the issue has an MR (matches PipelineMonitor and
    # captures detached/MR pipelines a branch-ref query would miss); otherwise
    # the latest branch pipeline (pre-MR lifecycle).
    def relevant_pipeline
      return field(client.merge_request(project_path, mr_iid), :head_pipeline) if mr_iid

      client.pipelines(project_path, ref: branch, order_by: 'id', sort: 'desc', per_page: 1).first
    end

    # The most recent job named exactly `deploy_review` — `max_by(:id)` so a
    # retried pipeline (which keeps the superseded job in the list) resolves to
    # the live instance rather than a stale one. `per_page: 100` without
    # auto-pagination matches PipelineMonitor#fetch_failed_jobs: a deploy job
    # sits near the end of any realistic (<100-job) pipeline.
    def find_deploy_review_job(pipeline)
      client.pipeline_jobs(project_path, pipeline_id(pipeline), per_page: 100)
            .select { |job| job_name(job) == JOB_NAME }
            .max_by { |job| job_id(job) }
    end

    def client
      @client ||= ::GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @config['gitlab_token'])
    end

    def project_path
      @issue.project_path
    end

    def branch
      @issue.branch_name
    end

    def mr_iid
      @issue.mr_iid
    end

    # Map the job's status onto an Outcome: actionable (:available + :play or
    # :retry) or not (:blocked upstream, :running in flight, :unknown for any
    # status outside every bucket).
    def classify(job)
      status = job_status(job).to_s
      return Outcome.new(state: :available, action: :play) if PLAYABLE.include?(status)
      return Outcome.new(state: :available, action: :retry) if RETRYABLE.include?(status)
      return Outcome.new(state: :blocked) if BLOCKED.include?(status)
      return Outcome.new(state: :running) if IN_FLIGHT.include?(status)

      Outcome.new(state: :unknown)
    end

    def play_or_retry(job, action)
      action == :play ? client.job_play(project_path, job_id(job)) : client.job_retry(project_path, job_id(job))
    end

    # GitLab gem objects answer to readers; plain Hashes (tests, cached rows)
    # answer to string keys. Tolerate both.
    def field(obj, name)
      obj.respond_to?(name) ? obj.public_send(name) : obj[name.to_s]
    end

    def job_id(job)
      field(job, :id)
    end

    def job_name(job)
      field(job, :name)
    end

    def job_status(job)
      field(job, :status)
    end

    def pipeline_id(pipeline)
      field(pipeline, :id)
    end
  end
end
