# frozen_string_literal: true

require 'socket'

# Allocates ephemeral host ports for app.run entries that declare a container port.
# Ports are held open (via TCPServer) until explicitly released, preventing the OS
# from reassigning them before Docker binds.
# Returns an array of { host_port:, container_port:, command:, server: } hashes.
module PortAllocator
  # Allocate host ports for all app.run entries that have a port.
  # Returns an array of resolved mappings, empty if no ports needed.
  # Callers must call release(mappings) after the consuming process has started.
  def self.allocate(project_config)
    entries = project_config.dig('app', 'run')
    return [] unless entries.is_a?(Array)

    entries.filter_map { |entry| allocate_entry(entry) }
  end

  # Close all held TCPServer sockets so the ports become available to Docker.
  def self.release(mappings)
    mappings.each { |m| m[:server]&.close rescue nil } # rubocop:disable Style/RescueModifier
  end

  # Returns danger-claude -P args for the given mappings.
  def self.dc_port_args(mappings)
    mappings.flat_map { |m| ['-P', "#{m[:host_port]}:#{m[:container_port]}"] }
  end

  def self.allocate_entry(entry)
    container_port = entry['port']
    return nil unless container_port

    server = TCPServer.new('127.0.0.1', 0)
    host_port = server.addr[1]
    { host_port: host_port, container_port: container_port, command: entry['command'], server: server }
  end
  private_class_method :allocate_entry
end
