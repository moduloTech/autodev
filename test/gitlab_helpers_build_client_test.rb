# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/gitlab_request_counter'

# Autodev #96: GitlabHelpers.build_gitlab_client is the single place the
# codebase turns a URL + token into a Gitlab::Client (confirmed by grep in
# the design spec — twelve call sites, one `Gitlab.client` call). Wrapping
# its return value here is what instruments every one of those twelve call
# sites without touching any of them.
class GitlabHelpersBuildClientTest < Minitest::Test
  def test_wraps_the_client_in_a_gitlab_request_counter
    raw = Object.new
    result = Gitlab.stub(:client, raw) { GitlabHelpers.build_gitlab_client('https://gitlab.example', 'tok') }

    assert_instance_of GitlabRequestCounter, result
  end

  def test_still_raises_without_a_token
    assert_raises(ConfigError) { GitlabHelpers.build_gitlab_client('https://gitlab.example', nil) }
  end

  def test_still_raises_without_a_gitlab_url
    assert_raises(ConfigError) { GitlabHelpers.build_gitlab_client(nil, 'tok') }
  end
end
