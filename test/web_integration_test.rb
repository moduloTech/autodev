# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'
require 'net/http'
require 'socket'

# End-to-end: boot the real Puma server, drive an issue through transitions,
# verify the dashboard reflects the changes via real HTTP.
class WebIntegrationTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
    Web::EventBus.reset!
    @port = free_port
    Web::Server.start({ 'web' => { 'enabled' => true, 'port' => @port }, 'gitlab_url' => 'https://example.com' })
    wait_until_listening
  end

  def teardown
    Web::Server.stop
  end

  def test_dashboard_reflects_active_issue_count
    create_issue(status: 'cloning', issue_title: 'Live test')

    body = http_get('/').body

    assert_includes body, 'Live test'
  end

  def test_issue_detail_shows_transition_history
    issue = create_issue
    issue.start_processing!
    issue.clone_complete!

    body = http_get("/issues/#{issue.id}").body.force_encoding('UTF-8')

    assert_includes body, 'pending → cloning'
    assert_includes body, 'cloning → checking_spec'
  end

  def test_post_reset_via_real_http_clears_error
    issue = create_issue(status: 'error', error_message: 'kaboom', retry_count: 5)

    Net::HTTP.post(URI("http://127.0.0.1:#{@port}/issues/#{issue.id}/reset"), '')

    assert_equal 'pending', Issue[issue.id].status
  end

  def test_assets_route_serves_turbo_over_real_http
    response = http_get('/assets/turbo.js')

    assert_equal '200', response.code
    assert_predicate response.body.length, :positive?
  end

  private

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_until_listening
    deadline = Time.now + 5
    until Time.now > deadline
      return if try_connect

      sleep 0.05
    end
    raise 'server never came up'
  end

  def try_connect
    TCPSocket.new('127.0.0.1', @port).close
    true
  rescue StandardError
    false
  end

  def http_get(path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}#{path}"))
  end
end
