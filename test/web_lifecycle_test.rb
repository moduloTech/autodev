# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'
require 'net/http'
require 'socket'

class WebLifecycleTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
    Web::EventBus.reset!
  end

  def teardown
    Web::Server.stop
  end

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  def test_start_returns_nil_when_once_mode
    assert_nil Web::Server.start({ 'once' => true, 'web' => { 'enabled' => true, 'port' => free_port } })
  end

  def test_start_returns_nil_when_web_disabled
    assert_nil Web::Server.start({ 'web' => { 'enabled' => false } })
  end

  def test_start_returns_nil_when_web_block_missing
    assert_nil Web::Server.start({})
  end

  def test_start_serves_a_request
    port = free_port
    Web::Server.start({ 'web' => { 'enabled' => true, 'port' => port } })
    response = wait_for_http(port, '/')

    assert_equal '200', response.code
  end

  def test_stop_is_idempotent_when_never_started
    Web::Server.stop
    Web::Server.stop # should not raise
  end

  def test_start_honors_custom_bind
    port = free_port
    # 127.0.0.2 is loopback too — proves the bind value reaches Puma without
    # opening the test up to the network. Hitting 127.0.0.1 on the same port
    # should refuse since the listener is on a different address.
    Web::Server.start({ 'web' => { 'enabled' => true, 'port' => port, 'bind' => '127.0.0.2' } })
    response = wait_for_http(port, '/', host: '127.0.0.2')

    assert_equal '200', response.code
    assert_kind_of Exception, try_http(port, '/', host: '127.0.0.1')
  rescue Errno::EADDRNOTAVAIL
    skip '127.0.0.2 not available as a loopback alias on this host'
  end

  private

  # Poll the port until Puma accepts connections (race-free startup).
  def wait_for_http(port, path, host: '127.0.0.1')
    deadline = Time.now + 5
    last_err = nil
    until Time.now > deadline
      result = try_http(port, path, host: host)
      return result unless result.is_a?(Exception)

      last_err = result
      sleep 0.05
    end
    raise last_err || RuntimeError.new('server never came up')
  end

  def try_http(port, path, host: '127.0.0.1')
    Net::HTTP.get_response(URI("http://#{host}:#{port}#{path}"))
  rescue StandardError => e
    e
  end
end
