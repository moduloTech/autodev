# frozen_string_literal: true

module Web
  # Encapsulates Puma server boot/teardown for the embedded Web::Server.
  # Mixed into Web::Server as class methods.
  module Lifecycle
    DEFAULT_PORT = 4567
    DEFAULT_BIND = '127.0.0.1'
    JOIN_TIMEOUT = 5

    attr_accessor :app_config

    # Wire the loaded autodev config into the app. Called once at boot.
    def configure_with(config)
      @app_config = config || {}
    end

    # Boot a background Puma server bound to `web.bind` (default 127.0.0.1).
    # Returns the chosen port if started, nil if disabled or already running.
    def start(config, logger: nil)
      return nil if @puma_server
      return nil if config['once']
      return nil unless config.dig('web', 'enabled')

      configure_with(config)
      port = config.dig('web', 'port') || DEFAULT_PORT
      bind = config.dig('web', 'bind') || DEFAULT_BIND
      logger&.info("Web UI listening on http://#{bind}:#{port}")
      boot_puma!(bind, port)
      port
    end

    def stop
      return unless @puma_server

      Web::EventBus.shutdown!
      @puma_server.stop(true)
      @puma_thread&.join(JOIN_TIMEOUT)
      @puma_server = nil
      @puma_thread = nil
    end

    private

    def boot_puma!(bind, port)
      require 'puma'

      @puma_server = Puma::Server.new(self, nil, min_threads: 0, max_threads: 8)
      @puma_server.add_tcp_listener(bind, port)
      @puma_thread = Thread.new { @puma_server.run.join }
    end
  end
end
