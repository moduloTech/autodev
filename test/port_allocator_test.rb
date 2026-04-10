# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/port_allocator'

class PortAllocatorTest < Minitest::Test
  def test_returns_empty_when_no_app_config
    assert_equal [], PortAllocator.allocate({})
  end

  def test_returns_empty_when_no_run_entries
    assert_equal [], PortAllocator.allocate({ 'app' => { 'setup' => [%w[bundle install]] } })
  end

  def test_returns_empty_when_run_entries_have_no_port
    config = { 'app' => { 'run' => [{ 'command' => %w[bin/vite dev] }] } }

    assert_equal [], PortAllocator.allocate(config)
  end

  def test_allocates_correct_container_port
    mappings = allocate_single_rails

    assert_equal 3000, mappings[0][:container_port]
    assert_equal %w[bin/rails s], mappings[0][:command]
  ensure
    PortAllocator.release(mappings) if mappings
  end

  def test_allocates_positive_host_port
    mappings = allocate_single_rails

    assert_predicate mappings[0][:host_port], :positive?
  ensure
    PortAllocator.release(mappings) if mappings
  end

  def test_server_held_open_until_release
    mappings = allocate_single_rails
    server = mappings[0][:server]

    refute_predicate server, :closed?
    PortAllocator.release(mappings)

    assert_predicate server, :closed?
  end

  def test_allocates_unique_ports_for_multiple_entries
    config = run_config(
      { 'command' => %w[bin/rails s], 'port' => 3000 },
      { 'command' => %w[bin/webpack], 'port' => 3010 }
    )
    mappings = PortAllocator.allocate(config)

    assert_equal 2, mappings.size
    refute_equal mappings[0][:host_port], mappings[1][:host_port]
  ensure
    PortAllocator.release(mappings) if mappings
  end

  def test_skips_entries_without_port
    config = run_config(
      { 'command' => %w[bin/rails s], 'port' => 3000 },
      { 'command' => %w[bin/vite dev] }
    )
    mappings = PortAllocator.allocate(config)

    assert_equal 1, mappings.size
    assert_equal 3000, mappings[0][:container_port]
  ensure
    PortAllocator.release(mappings) if mappings
  end

  def test_dc_port_args_formats_correctly
    mappings = [
      { host_port: 49_152, container_port: 3000, command: %w[bin/rails s] },
      { host_port: 49_153, container_port: 3010, command: %w[bin/webpack] }
    ]

    assert_equal ['-P', '49152:3000', '-P', '49153:3010'], PortAllocator.dc_port_args(mappings)
  end

  def test_dc_port_args_empty_for_no_mappings
    assert_equal [], PortAllocator.dc_port_args([])
  end

  def test_release_tolerates_empty_mappings
    PortAllocator.release([])
  end

  def test_release_tolerates_nil_server
    PortAllocator.release([{ host_port: 1234, container_port: 3000, server: nil }])
  end

  private

  def allocate_single_rails
    PortAllocator.allocate(run_config({ 'command' => %w[bin/rails s], 'port' => 3000 }))
  end

  def run_config(*entries)
    { 'app' => { 'run' => entries } }
  end
end
