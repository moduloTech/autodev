# frozen_string_literal: true

module Autodev
  # Did somebody other than autodev move this ticket on with its labels?
  # (Autodev #52)
  #
  # Autodev never re-read a ticket's labels, so a human who took the work back
  # had no way of saying so: on powerpanne/core #15894 the workflow label moved
  # from `Development::Doing` to `Development::Awaiting CR` and autodev kept
  # polling that MR's pipeline for two weeks.
  #
  # Two problems have to be solved together, and both shape this class.
  #
  # **Which label change means "stop".** It cannot be "a label autodev does not
  # know": real tickets permanently carry labels outside the workflow
  # (`PM::Evolution`, `Fourriere`, client names, `Backlog`), so that rule closes
  # everything. The verdict is therefore scoped to the GitLab label *scope*
  # autodev itself lives in, derived from `label_doing` + `label_done` — the two
  # labels autodev owns and writes. `labels_todo` is deliberately excluded from
  # the derivation: it is the entry point a human uses, and on powerpanne/core
  # it is GitLab's stock unscoped `To Do` while the other two are
  # `Development::…`, so including it would disable the rule on the very project
  # this was written for. The rule self-disables when the two share no scope,
  # leaving the two presence checks (doing removed / done added) — which is the
  # documented fallback, and why a project that does not follow the convention
  # carries no false-close risk.
  #
  # **Who made the edit.** Autodev applies and removes these very labels in
  # normal operation. Inferring the author from the state machine's expectation
  # is free but races: `apply_label_done` writes the GitLab label a few hundred
  # milliseconds before the row's status reaches `done`, from inside the
  # per-issue `limits_concurrency` lock the poll cycle does not hold. So the
  # author is read from GitLab's resource label events instead — but only as a
  # second stage, because that read costs an API call. Stage 1 works off the
  # `labels` array already present in the issue payload the caller fetched, and
  # on a healthy ticket it produces no candidate at all: nominal cost is zero.
  #
  # Everything unknown resolves to "do not stop". A missed handover costs what
  # the bug already costs; a wrong stop closes a live ticket and posts a comment
  # blaming somebody who did nothing.
  class LabelHandover
    Verdict = Struct.new(:reason, :label)

    SCOPE_SEPARATOR = '::'

    # The resource-label-event action each suspicion implies. An event carrying
    # the other one means the labels we read are stale, not that a human acted.
    EXPECTED_ACTION = { done_added: 'add', workflow_moved: 'add', doing_removed: 'remove' }.freeze

    def initialize(client:, path:, project_config:, logger:)
      @client = client
      @path = path
      @project_config = project_config || {}
      @logger = logger
    end

    # `nil` when nothing happened or when autodev did it itself; a Verdict when
    # somebody else moved the ticket on. `reason` is also the locale key suffix
    # the caller uses (`handover_#{reason}` / `activity_handover_#{reason}`).
    def verdict(gl_issue, issue_iid)
      suspicion = suspect(Array(::GitlabHelpers.field(gl_issue, :labels)))
      return unless suspicion
      return unless by_someone_else?(issue_iid, suspicion)

      suspicion
    end

    private

    # Stage 1 — free: the labels came with the issue payload the caller already
    # fetched.
    #
    # Ordered by informativeness, and the order matters because the three
    # overlap: applying a scoped label makes GitLab drop `label_doing` in the
    # same edit, so `workflow_moved` and `doing_removed` both hold and only the
    # first can name where the ticket went.
    def suspect(labels)
      return Verdict.new(:done_added, label_done) if label_done && labels.include?(label_done)

      moved = foreign_scoped(labels).first
      return Verdict.new(:workflow_moved, moved) if moved
      return Verdict.new(:doing_removed, label_doing) if label_doing && !labels.include?(label_doing)

      nil
    end

    # Labels sitting in autodev's own workflow scope that are none of the three
    # configured ones. Everything outside the scope is somebody else's taxonomy
    # and is none of our business.
    def foreign_scoped(labels)
      return [] unless scope

      labels.select { |label| scope_of(label) == scope } - configured_labels
    end

    def configured_labels = (labels_todo + [label_doing, label_done]).compact

    def scope
      return @scope if defined?(@scope)

      doing = scope_of(label_doing)
      @scope = doing && doing == scope_of(label_done) ? doing : nil
    end

    # A GitLab scoped label is `key::value`, the key being everything before the
    # *last* separator — `A::B::C` has key `A::B`. Unscoped labels have none.
    def scope_of(label)
      key, separator, = label.to_s.rpartition(SCOPE_SEPARATOR)
      separator.empty? ? nil : key
    end

    def label_doing = presence(@project_config['label_doing'])
    def label_done = presence(@project_config['label_done'])
    def labels_todo = Array(@project_config['labels_todo']).filter_map { |l| presence(l) }

    def presence(value) = value.to_s.strip.empty? ? nil : value.to_s

    # Stage 2 — one API call, spent only on a candidate, for a row that is about
    # to be closed. Not a recurring cost.
    def by_someone_else?(issue_iid, suspicion)
      event = last_event_for(issue_iid, suspicion.label)
      return false unless event
      return false unless ::GitlabHelpers.field(event, :action).to_s == EXPECTED_ACTION.fetch(suspicion.reason)

      actor = ::GitlabHelpers.field(::GitlabHelpers.field(event, :user), :id)
      !actor.nil? && actor != ::GitlabHelpers.current_user_id(@client)
    end

    # GitLab returns resource label events in chronological order, so the last
    # entry naming the label is the edit that produced the state we just read.
    # `label` is null once the label itself has been deleted; `field` answers
    # nil for that without a special case.
    def last_event_for(issue_iid, label_name)
      events = Array(@client.issue_label_events(@path, issue_iid))
      events.select { |e| ::GitlabHelpers.field(::GitlabHelpers.field(e, :label), :name) == label_name }.last
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to read label events for ##{issue_iid}: #{e.message}", project: @path)
      nil
    end
  end
end
