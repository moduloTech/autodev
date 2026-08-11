# frozen_string_literal: true

module Autodev
  # Retroactive application of the per-poll collapse (Autodev #53).
  #
  # `ActivityLogger` now supersedes a repeated activity entry in place instead
  # of appending a row, but the rows already written stay. Production carried
  # 477 827 of them out of 898 424 (53 %), in a 264 MB SQLite file, 29 773 on
  # issue #15894 alone — enough to make `/issues/15894` and the GitLab thread
  # unreadable, since both show the most recent entries.
  #
  # The rule is exactly the one the runtime now applies: **keep the most recent
  # occurrence of a collapsible key per issue, delete the superseded ones.**
  # That makes the pass idempotent by construction (a second run finds nothing),
  # leaves the current "still watching since X" line in place, and needs no
  # judgement about what a poll row is.
  #
  # Exposed as `bin/rails autodev:compact_activity_events` rather than a
  # migration: `config/initializers/auto_migrate.rb` runs migrations at boot in
  # every process (supervisor, web, worker), and a 478 000-row DELETE plus a
  # VACUUM of a 264 MB file must not happen on a schedule nobody chose. VACUUM
  # also cannot run inside the transaction AR wraps a migration in.
  #
  # Deletes nothing unless `apply:`. The production procedure — backup first,
  # then delete, then VACUUM separately — is in
  # docs/superpowers/specs/2026-08-11-bound-pipeline-watch-design.md.
  class ActivityEventCompaction
    # The activity keys whose call sites pass `replace_pattern:`, i.e. the ones
    # the runtime now collapses. Kept in sync with `PipelineMonitor`'s four
    # patterns (`POLL_LINE_PATTERN`, `PIPELINE_RED_PATTERN`,
    # `PIPELINE_INFRA_PATTERN`, `PIPELINE_EVAL_PATTERN`) — a key listed here but
    # no longer collapsed at runtime would simply have nothing to delete.
    COLLAPSIBLE_KEYS = %w[pipeline_checking pipeline_red pipeline_infra pipeline_evaluating].freeze

    BATCH_SIZE = 10_000

    def initialize(apply: false, vacuum: false, out: $stdout)
      @apply = apply
      @vacuum = vacuum
      @out = out
    end

    def run
      total = COLLAPSIBLE_KEYS.sum { |key| compact_key(key) }
      say(@apply ? "done: #{total} row(s) deleted" : "dry run: #{total} row(s) would be deleted (APPLY=1 to delete)")
      reclaim! if @vacuum
      total
    end

    private

    def compact_key(key)
      scope = rows_for(key)
      examined = scope.count
      superseded = scope.where.not(id: newest_ids(scope))
      count = superseded.count
      say(format('%<key>-22s %<examined>8d row(s), %<superseded>8d superseded, %<kept>d kept',
                 key: key, examined: examined, superseded: count, kept: examined - count))
      # in_batches so an interrupt costs at most one statement and a re-run
      # picks up where it stopped — the pass is idempotent either way.
      superseded.in_batches(of: BATCH_SIZE).delete_all if @apply && count.positive?
      count
    end

    # Same shape as `ActivityLogger.last_collapsible_event`: `payload_json` is
    # always produced by `JSON.generate(key:, vars:, message:)`, so the key is a
    # literal prefix. `issue_id` NULL is excluded because a system row
    # (`poller`, `error`, `usage`) has no issue to group by.
    def rows_for(key)
      ActivityEvent.where(kind: 'danger_claude').where.not(issue_id: nil)
                   .where('payload_json LIKE ? ESCAPE ?', "#{like_escape(%({"key":"#{key}",))}%", '\\')
    end

    def newest_ids(scope) = scope.group(:issue_id).maximum(:id).values

    def like_escape(text) = text.gsub(/[\\%_]/) { |char| "\\#{char}" }

    # Outside any transaction, and only ever on the connected database — which
    # in a test is the in-memory one. Needs free disk equal to the file and
    # takes an exclusive lock, hence the separate opt-in.
    def reclaim!
      return say('VACUUM skipped: nothing was deleted (APPLY=1 first)') unless @apply

      say('VACUUM…')
      ActiveRecord::Base.connection.execute('VACUUM')
      say('VACUUM done')
    end

    def say(line) = @out.puts("[autodev:compact_activity_events] #{line}")
  end
end
