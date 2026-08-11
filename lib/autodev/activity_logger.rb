# frozen_string_literal: true

# Maintains a single "activity log" comment on each GitLab issue,
# updated at each processing step so users can track autodev progress in real time.
#
# Two usage modes:
# - Instance method `log_activity` for processors (via DangerClaudeRunner include)
# - Class method `ActivityLogger.post` for standalone callers (Poller) via a Ctx struct
module ActivityLogger # rubocop:disable Metrics/ModuleLength
  def self.tag
    @tag ||= "**autodev** (v#{Autodev::VERSION})".freeze
  end

  # Lightweight context for standalone callers that lack DangerClaudeRunner.
  Ctx = Struct.new(:client, :project_path, :logger)

  # Post an activity entry. When `replace_pattern` is given, the last line of
  # the note is replaced instead of appended if it matches the pattern — and,
  # since Autodev #53, so is the `activity_events` row: one rule, both sinks.
  def self.post(ctx, issue, key, replace_pattern: nil, **vars)
    entry = build_entry(issue, key, **vars)
    persist_event!(issue, key, payload_for(key, entry, vars), collapse: !replace_pattern.nil?)
    note_id = issue.activity_note_id
    note_id ? upsert(ctx, issue, note_id, entry, replace_pattern) : create(ctx, issue, entry)
  rescue StandardError => e
    ctx.logger&.error("Activity log update failed: #{e.message}", project: ctx.project_path)
  end

  # Best-effort persistence to the activity_events table. Failures here must
  # never abort the GitLab note update — they are logged and swallowed.
  #
  # `collapse:` mirrors the note's `replace_pattern` (Autodev #53). Without it,
  # a ticket polled every cycle in `checking_pipeline` grew one row per poll:
  # 477 827 of production's 898 424 rows, 29 773 of them on a single issue,
  # which made both /issues/:id and the GitLab thread unreadable and put the
  # SQLite file at 264 MB.
  def self.persist_event!(issue, key, payload, level: 'info', collapse: false)
    previous = collapse ? last_collapsible_event(issue, key) : nil
    return supersede!(previous, level, payload) if previous

    ActivityEvent.create(issue_id: issue.id, kind: 'danger_claude', level: level, payload_json: payload)
  rescue StandardError
    nil
  end

  def self.payload_for(key, entry, vars)
    JSON.generate(key: key.to_s, vars: vars, message: entry)
  end

  # The previous occurrence of `key` on this issue, or nil.
  #
  # Bounded to the issue's own rows first, which is what keeps it cheap:
  # `idx_ae_issue` (issue_id, created_at) seeks the issue, and the LIKE filters
  # within that seek rather than scanning a table that is 900k rows wide. The
  # key is a literal JSON prefix because `payload_json` is always produced by
  # `JSON.generate(key:, vars:, message:)` right above.
  def self.last_collapsible_event(issue, key)
    ActivityEvent.where(issue_id: issue.id, kind: 'danger_claude')
                 .where('payload_json LIKE ? ESCAPE ?', "#{like_escape(%({"key":"#{key}",))}%", '\\')
                 .order(created_at: :desc, id: :desc).first
  end

  # Activity keys are snake_case and `_` is a LIKE wildcard, so an unescaped
  # `pipeline_checking` pattern would also match `pipelineXchecking`. No such
  # key exists; escaping costs one line and removes the class of bug.
  def self.like_escape(text) = text.gsub(/[\\%_]/) { |char| "\\#{char}" }

  # `update_columns`, not `update`: skipping `after_create_commit` is the point.
  # A re-occurrence must not push a Turbo frame — one per poll per watched row
  # is exactly the /stream noise this change removes. `created_at` deliberately
  # moves forward: for a collapsed row it means "last occurrence", the same
  # thing the note line's leading timestamp means, and it is what keeps
  # `Issue.without_activity_since` seeing the freshness it saw before the
  # collapse (Autodev #50's invariant reads this column).
  def self.supersede!(event, level, payload)
    event.update_columns(created_at: Time.current, level: level, payload_json: payload)
    event
  end

  # Emit a warn-level activity event to the DB only (no GitLab note update).
  # Use for technical signals like parse failures that belong in the web UI
  # but would be noise on the issue thread.
  def self.warn_event(issue, key, **vars)
    return unless issue

    entry = build_entry(issue, key, **vars)
    persist_event!(issue, key, payload_for(key, entry, vars), level: 'warn')
  rescue StandardError
    nil
  end

  # Liveness marker for one danger-claude call (Autodev #50). DB only — no
  # GitLab note update, so it costs one INSERT and leaves the issue thread
  # untouched — and no locale entry, because nothing renders it:
  # Issue.without_activity_since is its only reader.
  #
  # This is what bounds a live worker's silence. Per-state business events do
  # not: PipelineFixer emits one event on entering fixing_pipeline, then loops
  # over N failed jobs with two calls each and nothing in between.
  #
  # No-op without a tracked issue, same contract as warn_event.
  def self.heartbeat!(issue, label)
    return unless issue

    ActivityEvent.create(issue_id: issue.id, kind: 'heartbeat', level: 'info',
                         payload_json: JSON.generate(event: 'dc_call', label: label))
    nil
  rescue StandardError
    nil
  end

  def self.build_entry(issue, key, **vars)
    locale = (issue.locale || 'fr').to_sym
    message = Locales.t(:"activity_#{key}", locale: locale, tag: tag, **vars)
    "- `#{Time.now.strftime('%m-%d %H:%M')}` — #{message}"
  end

  def self.create(ctx, issue, first_entry)
    locale = (issue.locale || 'fr').to_sym
    header = Locales.t(:activity_header, locale: locale, tag: tag)
    note = ctx.client.create_issue_note(ctx.project_path, issue.issue_iid, "#{header}\n\n#{first_entry}")
    issue.update(activity_note_id: note.id)
  end

  # GitLab refuses notes over 1,000,000 chars. We aim well below so a slightly longer
  # next entry still fits in one round-trip and so we don't re-truncate every poll.
  MAX_NOTE_BYTES = 900_000

  def self.upsert(ctx, issue, note_id, entry, pattern)
    note = ctx.client.issue_note(ctx.project_path, issue.issue_iid, note_id)
    body = pattern ? replace_or_append(note.body, entry, pattern) : "#{note.body}\n#{entry}"
    body = enforce_size_cap(body, issue) if body.length > MAX_NOTE_BYTES
    ctx.client.edit_issue_note(ctx.project_path, issue.issue_iid, note_id, body)
  rescue Gitlab::Error::NotFound
    create(ctx, issue, entry)
  end

  # Keep the header (first two lines) + a localised truncation marker + the most
  # recent tail lines that fit under MAX_NOTE_BYTES. Idempotent: re-truncating an
  # already-truncated body just drops more old lines, the marker stays single.
  def self.enforce_size_cap(body, issue)
    lines = body.split("\n")
    marker = truncation_marker(issue)
    header = lines.first(2)
    rest = strip_existing_marker(lines.drop(2), marker)
    tail = take_tail_within(rest, budget_for(header, marker))
    (header + [marker] + tail).join("\n")
  end

  def self.truncation_marker(issue)
    Locales.t(:activity_truncation_marker, locale: (issue.locale || 'fr').to_sym)
  end

  def self.strip_existing_marker(rest, marker)
    rest.shift if rest.first == marker
    rest
  end

  def self.budget_for(header, marker)
    MAX_NOTE_BYTES - header.sum { |l| l.length + 1 } - marker.length - 1
  end

  # Return the longest suffix of `lines` whose joined byte length stays under `budget`.
  def self.take_tail_within(lines, budget)
    kept = []
    used = 0
    lines.reverse_each do |line|
      cost = line.length + 1
      break if used + cost > budget

      kept.unshift(line)
      used += cost
    end
    kept
  end

  # Remove the most recent line matching the pattern (wherever it sits in the body)
  # and append the fresh entry at the bottom. Without rindex, an event interleaved
  # between two other recurring events on the same poll cycle would never dedup —
  # we observed pipeline_red / pipeline_infra each growing by one line per poll on
  # issues stuck in checking_pipeline, hitting GitLab's 1M-char note cap after ~25
  # days and breaking every subsequent activity update with a 400.
  def self.replace_or_append(body, entry, pattern)
    lines = body.split("\n")
    idx = lines.rindex { |l| l.match?(pattern) }
    return "#{body}\n#{entry}" unless idx

    lines.delete_at(idx)
    lines.push(entry).join("\n")
  end

  private_class_method :build_entry, :create, :upsert, :replace_or_append, :persist_event!,
                       :enforce_size_cap, :take_tail_within, :truncation_marker,
                       :strip_existing_marker, :budget_for, :last_collapsible_event,
                       :like_escape, :supersede!, :payload_for

  # Instance method for processors (uses @client, @project_path from DangerClaudeRunner).
  private

  def log_activity(issue, key, replace_pattern: nil, **vars)
    ctx = ActivityLogger::Ctx.new(@client, @project_path, @logger)
    ActivityLogger.post(ctx, issue, key, replace_pattern: replace_pattern, **vars)
  rescue StandardError => e
    log_error "Activity log update failed: #{e.message}"
  end

  # Warn-level activity event, DB only. No-op if no issue is tracked.
  def log_activity_warn(key, **vars)
    ActivityLogger.warn_event(@dc_issue, key, **vars)
  end
end
