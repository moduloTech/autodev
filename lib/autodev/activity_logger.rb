# frozen_string_literal: true

# Maintains a single "activity log" comment on each GitLab issue,
# updated at each processing step so users can track autodev progress in real time.
#
# Two usage modes:
# - Instance method `log_activity` for processors (via DangerClaudeRunner include)
# - Class method `ActivityLogger.post` for standalone callers (Poller) via a Ctx struct
module ActivityLogger
  def self.tag
    @tag ||= "**autodev** (v#{Autodev::VERSION})".freeze
  end

  # Lightweight context for standalone callers that lack DangerClaudeRunner.
  Ctx = Struct.new(:client, :project_path, :logger)

  # Post an activity entry. When `replace_pattern` is given, the last line of
  # the note is replaced instead of appended if it matches the pattern.
  def self.post(ctx, issue, key, replace_pattern: nil, **vars)
    entry = build_entry(issue, key, **vars)
    note_id = issue.activity_note_id
    note_id ? upsert(ctx, issue, note_id, entry, replace_pattern) : create(ctx, issue, entry)
  rescue StandardError => e
    ctx.logger&.error("Activity log update failed: #{e.message}", project: ctx.project_path)
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

  def self.upsert(ctx, issue, note_id, entry, pattern)
    note = ctx.client.issue_note(ctx.project_path, issue.issue_iid, note_id)
    body = pattern ? replace_or_append(note.body, entry, pattern) : "#{note.body}\n#{entry}"
    ctx.client.edit_issue_note(ctx.project_path, issue.issue_iid, note_id, body)
  rescue Gitlab::Error::NotFound
    create(ctx, issue, entry)
  end

  def self.replace_or_append(body, entry, pattern)
    lines = body.split("\n")
    if lines.last&.match?(pattern)
      lines[-1] = entry
      lines.join("\n")
    else
      "#{body}\n#{entry}"
    end
  end

  private_class_method :build_entry, :create, :upsert, :replace_or_append

  # Instance method for processors (uses @client, @project_path from DangerClaudeRunner).
  private

  def log_activity(issue, key, replace_pattern: nil, **vars)
    ctx = ActivityLogger::Ctx.new(@client, @project_path, @logger)
    ActivityLogger.post(ctx, issue, key, replace_pattern: replace_pattern, **vars)
  rescue StandardError => e
    log_error "Activity log update failed: #{e.message}"
  end
end
