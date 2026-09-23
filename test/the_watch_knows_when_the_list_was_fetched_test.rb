# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Autodev #86, adversarial review. `SpecChecker#post_clarification` parks a row
# (`spec_unclear!`, then the stamp) before it reposes the entry label, so a row
# parked after `dispatch_new_issues` fetched its list is absent from it for that
# reason alone. The watch can only tell that case apart if it knows when the
# list was fetched — and the instant has to be taken *before* the fetch, or a
# row parked during it would read as parked before.
class TheWatchKnowsWhenTheListWasFetchedTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To Do'] }.freeze

  def setup
    setup_database
  end

  def dispatcher
    Autodev::PollDispatcher.allocate.tap do |d|
      { path: 'group/project', project_config: PROJECT_CONFIG, config: {}, logger: StubLogger.new,
        client: Object.new }.each { |name, value| d.instance_variable_set(:"@#{name}", value) }
    end
  end

  # Runs the two passes with GitLab's list stubbed empty; returns the keywords
  # the watch was built with and the instant the fetch happened.
  def run_passes
    captured = []
    fetched_at = nil
    fetch = ->(*) { (fetched_at = Time.current) && [] }
    spy = ->(**kw) { (captured << kw) && Struct.new(:run).new(0) }
    GitlabHelpers.stub(:current_user_id, 7) do
      GitlabHelpers.stub(:fetch_assignee_issues, fetch) do
        Autodev::ClarificationWatch.stub(:new, spy) { dispatch_both }
      end
    end
    [captured.first, fetched_at]
  end

  def dispatch_both
    d = dispatcher
    d.send(:dispatch_new_issues)
    d.send(:dispatch_clarification_watch)
  end

  def test_the_watch_is_given_an_instant_taken_before_the_fetch
    kwargs, fetched_at = run_passes

    assert_operator kwargs[:listed_at], :<=, fetched_at
  end
end
