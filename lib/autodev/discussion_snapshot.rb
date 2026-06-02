# frozen_string_literal: true

require 'json'
require 'time'

# Instrumentation for the suspected race between mr-review (which posts review
# comments as GitLab discussion notes) and the next `fetch_unresolved_discussions`
# poll. Observed on Powerpanne issue #11859 (2026-05-28): immediately after a
# successful mr-review run, `green_post_review` saw `count = 0` and transitioned
# the issue to `done` — yet 12 unresolved threads existed on the MR when the
# user checked manually. Without ground-truth timestamps and per-discussion
# state from both sides of the suspected race, the root cause can't be pinned
# (mr-review draft note delay? GitLab indexing? auto_paginate truncation?).
#
# This module emits a single ground-truth snapshot at every relevant moment:
# - `:post_mr_review` after mr-review returns successfully
# - `:pre_fix_dispatch` before PipelineMonitor's `green_post_review` decides
#   between `done` and `fixing_discussions`
# - `:pre_mr_fix` before MrFixer iterates and resolves discussions
#
# Each snapshot is logged at DEBUG and persisted as an `activity_events` row
# with `kind='discussions_snapshot'` so it can be queried via SQL on the prod
# DB (see `reference_autodev_prod_db.md` for access).
module DiscussionSnapshot
  # Lightweight bundle of identifiers + sinks. Reduces the parameter footprint
  # of capture/persist call sites, and lets future call sites pass extra
  # metadata without churn.
  Ctx = Struct.new(:client, :project_path, :mr_iid, :logger, :issue)

  # Capture and emit a snapshot. Always safe to call: API failures, persistence
  # failures, missing methods on the discussion objects are all swallowed so
  # the instrumentation can never break the workflow it's instrumenting.
  def self.capture(context:, **ctx_kwargs)
    ctx = Ctx.new(**ctx_kwargs)
    raw = fetch_all_discussions(ctx)
    payload = build_payload(raw, context: context, mr_iid: ctx.mr_iid)
    log_summary(ctx, payload)
    persist(ctx.issue, payload) if ctx.issue
    payload
  rescue StandardError => e
    ctx&.logger&.debug("DiscussionSnapshot capture failed: #{e.class}: #{e.message}",
                       project: ctx&.project_path)
    nil
  end

  def self.fetch_all_discussions(ctx)
    ctx.client.merge_request_discussions(ctx.project_path, ctx.mr_iid, per_page: 100).auto_paginate
  rescue StandardError => e
    ctx.logger&.debug("DiscussionSnapshot fetch failed: #{e.class}: #{e.message}",
                      project: ctx.project_path)
    []
  end

  def self.build_payload(discussions, context:, mr_iid:)
    items = discussions.map { |d| summarize(d) }
    { context: context.to_s, mr_iid: mr_iid, captured_at: Time.now.utc.iso8601,
      total: items.size, unresolved: items.count { |i| i[:unresolved] },
      discussions: items }
  end

  def self.summarize(discussion)
    notes = discussion.notes || []
    counts = note_counts(notes)
    first = notes.first
    { id: discussion.id.to_s[0, 8], author: author_username(first),
      created_at: safe_call(first, :created_at), notes_total: notes.size,
      notes_resolvable: counts[:resolvable], notes_resolved: counts[:resolved],
      unresolved: counts[:resolvable].positive? && counts[:resolved] < counts[:resolvable],
      position: position_str(first) }
  end

  def self.note_counts(notes)
    resolvable = notes.select { |n| safe_call(n, :resolvable) }
    { resolvable: resolvable.size,
      resolved: resolvable.count { |n| safe_call(n, :resolved) } }
  end

  # GitLab's `author` is a Hashie::Mash on the gem; accept both Hash and
  # method-access shapes to stay future-proof against gem version bumps.
  def self.author_username(note)
    author = safe_call(note, :author)
    return nil unless author

    author.respond_to?(:[]) ? author['username'] : safe_call(author, :username)
  end

  def self.position_str(note)
    pos = safe_call(note, :position)
    return 'general' unless pos

    line = pos['new_line'] || pos['old_line']
    path = pos['new_path'] || pos['old_path']
    line.nil? ? "#{path}:outdated" : "#{path}:#{line}"
  end

  def self.safe_call(obj, method)
    return nil unless obj.respond_to?(method)

    obj.send(method)
  end

  def self.log_summary(ctx, payload)
    ids = payload[:discussions].map { |d| d[:id] }.join(',')
    ctx.logger&.debug(
      "discussions_snapshot[#{payload[:context]}] mr=#{payload[:mr_iid]} " \
      "total=#{payload[:total]} unresolved=#{payload[:unresolved]} ids=#{ids}",
      project: ctx.project_path
    )
  end

  def self.persist(issue, payload)
    return unless Object.const_defined?(:ActivityEvent)

    ActivityEvent.create(
      issue_id: issue.id, kind: 'discussions_snapshot', level: 'info',
      payload_json: JSON.generate(payload)
    )
  rescue StandardError
    nil
  end
end
