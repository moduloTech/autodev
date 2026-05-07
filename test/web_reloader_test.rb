# frozen_string_literal: true

require_relative 'test_helper'

class WebReloaderTest < Minitest::Test
  # The reloader is opt-in via AUTODEV_WEB_RELOAD. The class flag
  # `Sinatra::Reloader` is registered only when the env var is set
  # at the time `web/server.rb` is required.
  #
  # Without the env var, requiring `autodev/web` should NOT register
  # the reloader.
  def test_reloader_is_not_registered_by_default
    require 'autodev/web'
    extensions = Web::Server.extensions

    refute_includes extensions.map(&:to_s), 'Sinatra::Reloader',
                    'Sinatra::Reloader should not be registered without AUTODEV_WEB_RELOAD'
  end
end
