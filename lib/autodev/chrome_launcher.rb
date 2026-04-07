# frozen_string_literal: true

require 'net/http'

# Manages the Chrome browser lifecycle for DevTools MCP support.
# Launches a headless Chrome instance with remote debugging if one isn't already running.
module ChromeLauncher
  CHROME_PORT = 9222
  PROFILE_DIR = File.join(Config::CONFIG_DIR, 'chrome-profile')

  CHROME_BINARIES = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    'google-chrome',
    'google-chrome-stable',
    'chromium-browser',
    'chromium'
  ].freeze

  CHROME_FLAGS = %w[
    --headless=new --no-first-run --disable-gpu --no-sandbox
  ].freeze

  module_function

  def ensure_running!(logger:)
    if running?
      logger.info('Chrome already running on port 9222')
      return
    end

    launch!(logger: logger)
  end

  def running?
    uri = URI("http://127.0.0.1:#{CHROME_PORT}/json/version")
    Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) do |http|
      http.get(uri.path).is_a?(Net::HTTPSuccess)
    end
  rescue StandardError
    false
  end

  def launch!(logger:)
    bin = detect_binary
    raise ConfigError, 'Chrome/Chromium not found on PATH' unless bin

    logger.info("Launching Chrome (#{bin}) on port #{CHROME_PORT}...")
    pid = spawn_chrome(bin)
    Process.detach(pid)
    wait_for_ready!(timeout: 10)
    logger.info("Chrome launched (PID #{pid})")
  end

  def spawn_chrome(bin)
    Process.spawn(
      bin,
      "--remote-debugging-port=#{CHROME_PORT}",
      '--remote-allow-origins=*',
      "--user-data-dir=#{PROFILE_DIR}",
      *CHROME_FLAGS,
      in: :close, out: '/dev/null', err: '/dev/null'
    )
  end

  def detect_binary
    CHROME_BINARIES.find do |bin|
      _, status = Open3.capture2e('which', bin)
      status.success?
    end
  end

  def wait_for_ready!(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if running?

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise ConfigError, "Chrome did not start within #{timeout}s"
      end

      sleep 0.5
    end
  end

  private_class_method :launch!, :spawn_chrome, :detect_binary, :wait_for_ready!
end
