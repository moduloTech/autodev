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

      event = decisive_event(issue_iid, suspicion)
      return unless event && by_someone_else?(event)

      suspicion
    end

    # The same question as `verdict`, bounded in time (Autodev #88): did somebody
    # else move this ticket on with its labels **after** `threshold`?
    #
    # `ReviewArrearsSweep` asks it of a request autodev abandoned and handed back
    # to its author. There the current labels alone answer nothing: autodev itself
    # posed `label_attention` on the way out, so `suspect` finds a candidate on
    # every row of that population and `verdict` would decline all of them. What
    # separates "autodev parked it there in July" from "a human moved it on since"
    # is *when* the edit was made, and the author of an edit is read off the
    # resource label events rather than inferred — the rule this class exists for.
    def moved_since?(gl_issue, issue_iid, threshold)
      return false if threshold.nil?

      suspicion = suspect(Array(::GitlabHelpers.field(gl_issue, :labels)))
      return false unless suspicion

      event = decisive_event(issue_iid, suspicion)
      !event.nil? && applied_after?(event, threshold) && by_someone_else?(event)
    end

    # Did somebody ask again *after* we stopped? Autodev #52 makes a stop
    # terminal (`closed`), which would otherwise turn the documented "repose the
    # todo label and reassign me" loop into a dead end — `PollRouter` only ever
    # re-entered from `done`.
    #
    # The threshold is what makes this safe to allow from `closed` at all: a row
    # an operator closed by hand from the dashboard carries a todo label that was
    # applied *before* the close, so it stays closed and the button keeps working
    # as an off-switch. Only a fresh application counts as a new request.
    def todo_reapplied_after?(issue_iid, threshold)
      return false if threshold.nil? || labels_todo.empty?

      events(issue_iid).any? do |event|
        ::GitlabHelpers.field(event, :action).to_s == 'add' &&
          labels_todo.include?(label_name(event)) &&
          applied_after?(event, threshold)
      end
    end

    # The removal side of the definition this class already owns (Autodev #98).
    #
    # `foreign_scoped` answers "in my scope but not mine", and until now it only
    # ever *detected* a handover. It has to *remove* too, because GitLab does not:
    # scoped-label exclusivity is a Premium feature and source.modulotech.fr
    # answers `enterprise: false`, so `LabelManager#manage_labels` — which sends
    # the whole list — has `Development::Awaiting CR` travel right back in beside
    # the `Development::Doing` it poses, and the ticket shows two states of one
    # scope. Measured on powerpanne/core#16224 on 02/09/2026; and #11339 carries
    # `Awaiting CR` beside `Awaiting Feature Review` with no autodev in the story,
    # which is the same fact without autodev's help.
    #
    # Only when `applied` is itself in the scope: autodev owns that scope while it
    # writes a value into it, and nowhere else. Reposing the entry label — which on
    # powerpanne is GitLab's unscoped `To do` — is not a claim over
    # `Development::*` and must not silently clear somebody else's column.
    #
    # Deliberately NOT a second definition of the scope: `label_attention` is
    # excluded from the derivation and included in `configured_labels`, and both
    # of those are decisions with reasons above. A copy in `LabelManager` would be
    # free to drift from them.
    def scope_residue(labels, applied)
      return [] unless applied && scope && scope_of(applied) == scope

      foreign_scoped(labels)
    end

    private

    def applied_after?(event, threshold)
      at = ::GitlabHelpers.field(event, :created_at)
      at && Time.parse(at.to_s) > threshold
    rescue ArgumentError, TypeError
      false
    end

    # Stage 1 — free: the labels came with the issue payload the caller already
    # fetched.
    #
    # Ordered by informativeness, and the order matters because the three
    # overlap: whoever moves the ticket on removes `label_doing` and adds the new
    # value in the same edit, so `workflow_moved` and `doing_removed` both hold
    # and only the first can name where the ticket went.
    #
    # The overlap comes from the *actor* — GitLab's board issues both changes in
    # one request, and `LabelManager#other_workflow_labels` lists `label_doing`
    # for the same reason — never from GitLab dropping the old value by itself.
    # It does not: scoped-label exclusivity is Premium (Autodev #98).
    def suspect(labels)
      return Verdict.new(:done_added, label_done) if label_done && labels.include?(label_done)

      moved = foreign_scoped(labels).first
      return Verdict.new(:workflow_moved, moved) if moved
      return Verdict.new(:doing_removed, label_doing) if doing_dropped?(labels)

      nil
    end

    # `label_doing` being gone is the weakest of the three signals: an absence,
    # not an edit naming where the ticket went. A todo label sitting on the row
    # explains that absence differently. The documented "repose the todo label and
    # reassign me" gesture drops `label_doing` in the same edit — because the
    # person doing it removes it, or because `apply_label_todo` does
    # (`other_workflow_labels` lists it), not because GitLab enforces one value
    # per scope; it does not, that is Premium (Autodev #98). On a project whose
    # todo shares the workflow scope — ff/fast/core configures `Development::ToDo`
    # against `Development::Doing` — that gesture therefore arrives here looking
    # exactly like a handover. Stopping on it
    # would park the ticket for good: the row goes to `closed`, and
    # `todo_reapplied_after?` gates reentry on a todo applied *after*
    # `finished_at`, which this one precedes. Somebody asking for work is never
    # a reason to stop, so the absence is left to PollRouter to read.
    def doing_dropped?(labels)
      return false unless label_doing
      return false if labels.include?(label_doing)

      !labels_todo.intersect?(labels)
    end

    # Labels sitting in autodev's own workflow scope that are none of the three
    # configured ones. Everything outside the scope is somebody else's taxonomy
    # and is none of our business.
    def foreign_scoped(labels)
      return [] unless scope

      labels.select { |label| scope_of(label) == scope } - configured_labels
    end

    # `label_attention` is in here for the same reason the other three are: it is
    # a label autodev writes (Autodev #63 — the end label of a give-up), it sits
    # in the derived scope by design, and a re-armed row can still be carrying it
    # when this runs. Leaving it out would send every abandoned-then-recovered
    # ticket into stage 2, where the only thing standing between it and a false
    # close is winning the authorship race this class was written not to depend
    # on. It is excluded from the scope *derivation* though: a project that
    # spells it outside the workflow scope must not disable the rule.
    def configured_labels = (labels_todo + [label_doing, label_done, label_attention]).compact

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
    def label_attention = presence(@project_config['label_attention'])
    def labels_todo = Array(@project_config['labels_todo']).filter_map { |l| presence(l) }

    def presence(value) = value.to_s.strip.empty? ? nil : value.to_s

    # Stage 2 — one API call, spent only on a candidate, for a row that is about
    # to be closed. Not a recurring cost.
    #
    # The edit that produced the state we read, or nil when the events disagree
    # with it: an event carrying the other action means the labels are stale, not
    # that a human acted.
    def decisive_event(issue_iid, suspicion)
      event = last_event_for(issue_iid, suspicion.label)
      return unless event
      return unless ::GitlabHelpers.field(event, :action).to_s == EXPECTED_ACTION.fetch(suspicion.reason)

      event
    end

    def by_someone_else?(event)
      actor = ::GitlabHelpers.field(::GitlabHelpers.field(event, :user), :id)
      !actor.nil? && actor != ::GitlabHelpers.current_user_id(@client)
    end

    # GitLab returns resource label events in chronological order, so the last
    # entry naming the label is the edit that produced the state we just read.
    def last_event_for(issue_iid, name)
      events(issue_iid).select { |e| label_name(e) == name }.last
    end

    # `label` is null once the label itself has been deleted; `field` answers nil
    # for that without a special case.
    def label_name(event) = ::GitlabHelpers.field(::GitlabHelpers.field(event, :label), :name)

    def events(issue_iid)
      Array(@client.issue_label_events(@path, issue_iid))
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to read label events for ##{issue_iid}: #{e.message}", project: @path)
      []
    end
  end
end
