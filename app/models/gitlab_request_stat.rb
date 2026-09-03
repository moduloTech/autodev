# frozen_string_literal: true

# Autodev #96: an hourly counter of GitLab API calls, one row per
# (hour_bucket, kind, endpoint). Written by GitlabRequestCounter
# (lib/autodev/gitlab_request_counter.rb), which wraps the client
# GitlabHelpers.build_gitlab_client returns so every call — read and write —
# is counted without any call site changing. Read back by
# Autodev::HealthReport's `gitlab_requests` check.
#
# A counter, not a log: `record!` upserts, so the table grows by at most a
# few dozen rows an hour (distinct endpoints × 2 kinds), not one row per
# call. See the design spec (docs/superpowers/specs/
# 2026-09-03-count-gitlab-requests-design.md) for why this and
# GitlabTransportFailure are shaped differently.
class GitlabRequestStat < ApplicationRecord
  class << self
    # Bumps the row for the hour `at` falls in. Fails closed: a broken write
    # here must never turn a successful (or a failed) GitLab call into a
    # second failure — the caller has already gotten its answer, or raised,
    # by the time this runs.
    def record!(kind:, endpoint:, at: Time.current)
      upsert_all([upsert_row(kind, endpoint, at.utc)],
                 unique_by: %i[hour_bucket kind endpoint],
                 on_duplicate: Arel.sql('count = count + 1, updated_at = excluded.updated_at'))
      nil
    rescue StandardError
      nil
    end

    # { 'read' => n, 'write' => n } for buckets whose hour starts at or after
    # `since`'s own hour — an approximation at the bucket boundary (a bucket
    # starting a little before `since` is excluded even if part of it falls
    # inside the window), acceptable for an observability figure that is
    # never the last word on an exact count.
    def by_kind_since(since)
      where(hour_bucket: since.utc.change(min: 0, sec: 0, usec: 0)..).group(:kind).sum(:count)
    end

    def total_since(since)
      by_kind_since(since).values.sum
    end

    private

    def upsert_row(kind, endpoint, now)
      bucket = now.change(min: 0, sec: 0, usec: 0)
      { hour_bucket: bucket, kind: kind.to_s, endpoint: endpoint.to_s, count: 1,
        created_at: now, updated_at: now }
    end
  end
end
