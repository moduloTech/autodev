# frozen_string_literal: true

require 'json'

# Injects Chrome DevTools MCP configuration, proxy scripts, and skill
# into the danger-claude Docker volume so Claude inside the container
# can use chrome-devtools MCP tools.
module ChromeDevtoolsInjector
  VOLUME_NAME = 'danger-claude'

  MCP_SERVER_CONFIG = {
    'type' => 'stdio',
    'command' => 'mise',
    'args' => ['x', 'node', '--', 'npx', '-y', 'chrome-devtools-mcp@latest',
               '--browser-url=http://127.0.0.1:9223'],
    'env' => {}
  }.freeze

  # Files to bind-mount into the container (host_path => container_path).
  PROXY_FILES = {
    '~/.claude/bin/chrome-devtools-proxy.mjs' => '/home/claude/.claude/bin/chrome-devtools-proxy.mjs',
    '~/.claude/bin/chrome-devtools-proxy' => '/home/claude/.claude/bin/chrome-devtools-proxy'
  }.freeze

  SKILL_DIR = {
    '~/.claude/skills/chrome-devtools-proxy' => '/home/claude/.claude/skills/chrome-devtools-proxy'
  }.freeze

  module_function

  # Inject MCP config into the Docker volume's .claude.json (idempotent).
  # Call once at startup, before workers.
  def inject_mcp_config!(logger:)
    json_str = read_volume_file('.claude.json')
    config = json_str ? JSON.parse(json_str) : {}
    config['mcpServers'] ||= {}

    if config['mcpServers']['chrome-devtools'] == MCP_SERVER_CONFIG
      logger.debug('Chrome DevTools MCP already configured in volume')
      return
    end

    config['mcpServers']['chrome-devtools'] = MCP_SERVER_CONFIG
    write_volume_file('.claude.json', JSON.pretty_generate(config))
    logger.info('Injected Chrome DevTools MCP config into danger-claude volume')
  end

  # Returns danger-claude CLI args to bind-mount proxy and skill.
  def dc_args
    volume_args.flat_map { |vol| ['-v', vol] }
  end

  # Returns volume mount strings for proxy and skill files.
  def volume_args
    args = []
    PROXY_FILES.merge(SKILL_DIR).each do |host_path, container_path|
      expanded = File.expand_path(host_path)
      next unless File.exist?(expanded)

      args << "#{expanded}:#{container_path}:ro"
    end
    args
  end

  # -- Volume I/O via one-shot Docker containers --------------------------------

  def read_volume_file(path)
    out, status = Open3.capture2(
      'docker', 'run', '--rm',
      '-v', "#{VOLUME_NAME}:/data:ro",
      'alpine', 'cat', "/data/#{path}"
    )
    status.success? ? out : nil
  end

  def write_volume_file(path, content)
    dir = File.dirname(path)
    # Ensure parent directory exists, then write file
    Open3.capture2(
      'docker', 'run', '--rm', '-i',
      '-v', "#{VOLUME_NAME}:/data",
      'alpine', 'sh', '-c', "mkdir -p /data/#{dir} && cat > /data/#{path}",
      stdin_data: content
    )
  end

  private_class_method :read_volume_file, :write_volume_file
end
