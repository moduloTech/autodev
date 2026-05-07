# frozen_string_literal: true

require 'rack/test'
require 'autodev/dashboard'
require 'autodev/web'

# Shared setup for tests that drive Web::Server through Rack::Test.
module WebServerTestSetup
  def app
    Web::Server
  end

  def setup
    setup_database
    Web::Server.configure_with(
      'gitlab_url' => 'https://gitlab.example.com',
      'projects' => [{ 'path' => 'group/project', 'app' => { 'test' => [['bin/test']] } }]
    )
  end
end
