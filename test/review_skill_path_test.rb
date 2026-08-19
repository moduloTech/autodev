# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'

# Which path runs, and what each one does to the counters (Autodev #74).
class ReviewSkillPathTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup = setup_database

  def monitor(review_skill:, skill_result: true, binary_called: [])
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@project_config, review_skill ? { 'review_skill' => review_skill } : {})
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:log_activity) { |*| nil }
    mon.define_singleton_method(:snapshot) { |*| nil }
    mon.define_singleton_method(:review_with_skill) { |_| skill_result }
    mon.define_singleton_method(:execute_mr_review) { |_| binary_called << true and true }
    mon
  end

  def issue
    Issue.create!(project_path: 'g/a', issue_iid: 1, mr_iid: 7, status: 'reviewing',
                  review_count: 0, review_failure_count: 0, locale: 'fr')
  end

  def test_a_project_with_a_review_skill_does_not_run_the_binary
    called = []
    row = issue
    monitor(review_skill: 'mr-review', binary_called: called).send(:launch_review, row)

    assert_empty called
    assert_equal 1, row.reload.review_count
  end

  def test_a_project_without_a_review_skill_runs_the_binary
    called = []
    monitor(review_skill: nil, binary_called: called).send(:launch_review, issue)

    assert_equal [true], called
  end

  def test_a_skill_review_failure_increments_the_failure_counter
    row = issue
    monitor(review_skill: 'mr-review', skill_result: false).send(:launch_review, row)

    assert_equal 1, row.reload.review_failure_count
    assert_equal 0, row.reload.review_count
  end

  def test_an_inconclusive_review_touches_neither_counter_and_returns_to_the_watch
    row = issue
    monitor(review_skill: 'mr-review', skill_result: :inconclusive).send(:launch_review, row)

    assert_equal 0, row.reload.review_count
    assert_equal 0, row.reload.review_failure_count
    assert_equal 'checking_pipeline', row.reload.status
  end

  def test_an_api_failure_while_publishing_burns_no_budget
    row = issue
    mon = monitor(review_skill: 'mr-review')
    mon.define_singleton_method(:review_with_skill) do |_|
      raise ApiUnavailableError.new(:mr_note, StandardError.new('boom'))
    end
    assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
    assert_equal 0, row.reload.review_failure_count
    assert_equal 0, row.reload.review_count
  end
end
