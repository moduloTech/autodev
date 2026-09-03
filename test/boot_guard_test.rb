# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/boot_guard'

# Autodev #92 design §2: `SIGKILL` leaves nothing to run, so no in-process
# `ensure` can reach a child that was already orphaned before this boot
# started — by the time a fresh supervisor starts, that orphan belongs to a
# *different*, already-dead process. The boot guard runs once, before
# anything is spawned, and looks only for what it can positively identify:
# a process holding our database file, reparented to pid 1 (adopted by
# launchd/init the way a crashed supervisor's children are), whose command
# matches one of ours.
#
# `holder_finder` is the one injection seam — it stands in for the real
# `lsof` + `ps` shell-outs, so the classification logic is tested without
# touching the OS.
class BootGuardTest < Minitest::Test
  # Drop-in replacement for AppLogger so we can assert on emissions.
  class FakeLogger
    attr_reader :entries

    def initialize
      @entries = []
    end

    %i[info warn error debug].each do |level|
      define_method(level) { |msg, **_| @entries << [level, msg] }
    end
  end

  def setup
    @logger = FakeLogger.new
    @killed = []
    @killer = ->(pid) { @killed << pid }
  end

  def test_a_recognized_rails_server_orphan_is_reaped_and_logged
    # The exact process title production measured post-boot (puma renames its
    # own $0 once it has bound the port — the pre-rename `bin/rails server`
    # command line is what a very fresh orphan would still show).
    holder = build_holder(pid: 555, ppid: 1, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder])

    guard.call

    assert_equal [555], @killed, 'a recognised orphan must be reaped'
    # `entries` is an Array of [level, msg] pairs, not a Hash — Style/HashSlice's
    # autocorrect misread this `select` as a Hash#slice candidate, which would
    # raise (Array#slice takes an index/range, not a key). rubocop:disable
    warn_lines = @logger.entries.select { |level, _| level == :warn } # rubocop:disable Style/HashSlice

    assert(warn_lines.any? { |_, msg| msg.include?('555') }, 'the reap must be logged, naming the pid')
  end

  def test_a_recognized_solid_queue_orphan_is_reaped_and_logged
    holder = build_holder(pid: 556, ppid: 1, command: 'solid-queue-fork-supervisor: supervising 1401, 1402, 1403')
    guard = build_guard(holders: [holder])

    guard.call

    assert_equal [556], @killed
    assert(@logger.entries.any? { |level, msg| level == :warn && msg.include?('556') })
  end

  def test_both_children_are_reaped_in_the_same_pass
    rails_orphan = build_holder(pid: 555, ppid: 1, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    queue_orphan = build_holder(pid: 556, ppid: 1, command: 'solid-queue-fork-supervisor: supervising 1401')
    guard = build_guard(holders: [rails_orphan, queue_orphan])

    guard.call

    assert_equal [555, 556], @killed.sort
  end

  def test_an_unrecognized_process_holding_the_database_refuses_the_boot
    holder = build_holder(pid: 777, ppid: 1, command: '/usr/bin/some-other-tool --scan /home/x/.autodev/autodev.db')
    guard = build_guard(holders: [holder])

    error = assert_raises(ConfigError) { guard.call }

    assert_includes error.message, '777'
    assert_empty @killed, 'an unrecognised holder must never be killed'
  end

  def test_a_recognized_command_not_reparented_to_pid_1_still_refuses
    # ppid != 1 means it is not an orphan of a dead supervisor — it could be a
    # live sibling under a *different*, still-running supervisor. The guard
    # only reaps what it can positively identify as an abandoned child.
    holder = build_holder(pid: 558, ppid: 4242, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder])

    error = assert_raises(ConfigError) { guard.call }

    assert_includes error.message, '558'
    assert_empty @killed
  end

  def test_nothing_holding_the_database_is_a_silent_pass
    guard = build_guard(holders: [])

    guard.call

    assert_empty @killed
    assert_empty @logger.entries
  end

  private

  def build_holder(pid:, ppid:, command:)
    Autodev::BootGuard::Holder.new(pid: pid, ppid: ppid, command: command)
  end

  def build_guard(holders:)
    Autodev::BootGuard.new(
      db_path: '/home/x/.autodev/autodev.db',
      logger: @logger,
      locale: :en,
      holder_finder: ->(_db_path) { holders },
      killer: @killer
    )
  end
end
