# frozen_string_literal: true

require_relative 'test_helper'

# The cost side of `ShallowHistory#ensure_merge_base!` (Autodev #138): a
# `--unshallow` fetches the whole history of the repository, which on
# powerpanne/core is the expensive fetch the deepening rounds exist to avoid.
# A merge base the last deepening round brings in must therefore be found
# before it, not after (phase-10 review of the alpha-58 lot).
class ShallowHistoryTest < Minitest::Test
  # A shallow clone whose merge base appears after `needed` deepening rounds.
  class FakeRepo
    include ShallowHistory

    attr_reader :fetches

    def initialize(needed)
      @needed = needed
      @deepens = 0
      @unshallowed = false
      @fetches = []
    end

    def run_cmd_status(cmd, chdir:) # rubocop:disable Lint/UnusedMethodArgument
      case cmd[1]
      when 'merge-base' then ['', '', @unshallowed || @deepens >= @needed]
      when 'rev-parse' then [(!@unshallowed).to_s, '', true]
      when 'fetch' then fetch(cmd[2])
      end
    end

    def fetch(mode)
      @fetches << mode
      mode == '--unshallow' ? @unshallowed = true : @deepens += 1
      ['', '', true]
    end

    public :ensure_merge_base!
  end

  def fetches_for(needed)
    FakeRepo.new(needed).tap { |repo| repo.ensure_merge_base!('/w', 'feat', 'master') }.fetches
  end

  def test_a_merge_base_brought_by_the_last_round_needs_no_unshallow
    assert_equal ['--deepen=500'] * ShallowHistory::DEEPEN_ROUNDS, fetches_for(ShallowHistory::DEEPEN_ROUNDS)
  end

  def test_a_merge_base_found_earlier_stops_the_deepening
    assert_equal ['--deepen=500'] * 2, fetches_for(2)
  end

  def test_a_fork_point_beyond_every_round_fetches_the_whole_history
    assert_equal (['--deepen=500'] * ShallowHistory::DEEPEN_ROUNDS) + ['--unshallow'],
                 fetches_for(ShallowHistory::DEEPEN_ROUNDS + 1)
  end
end
