# frozen_string_literal: true

require_relative '../rails_helper'

# The recurring half of Autodev #57: the sliding purge has to run on its own,
# because a manual rake task is exactly what Autodev #53 already shipped and it
# does not bound growth. Same shape as LogJanitorJob / ReapFailedJobsJob —
# scheduled in config/recurring.yml (production only), best-effort, never takes
# the worker down.
class PruneActivityEventsJobTest < ActiveSupport::TestCase
  test 'deletes the machinery rows past the retention window' do
    stale = ActivityEvent.create!(issue_id: nil, kind: 'poller', level: 'info',
                                  payload_json: '{}', created_at: 40.hours.ago)
    fresh = ActivityEvent.create!(issue_id: nil, kind: 'poller', level: 'info',
                                  payload_json: '{}', created_at: 1.minute.ago)

    PruneActivityEventsJob.new.perform

    refute ActivityEvent.exists?(stale.id)
    assert ActivityEvent.exists?(fresh.id)
  end

  test 'a janitor failure is swallowed rather than failing the job' do
    boom = ->(**) { raise 'disk on fire' }

    Autodev::ActivityEventJanitor.stub(:run, boom) do
      assert_nothing_raised { PruneActivityEventsJob.new.perform }
    end
  end
end
