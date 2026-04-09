# frozen_string_literal: true

require 'socket'

# Allocates ephemeral host ports for app.run entries that declare a container port.
# Returns an array of { host_port:, container_port:, command: } hashes.
module PortAllocator
  # Allocate host ports for all app.run entries that have a port.
  # Returns an array of resolved mappings, empty if no ports needed.
  def self.allocate(project_config)
    entries = project_config.dig('app', 'run')
    return [] unless entries.is_a?(Array)

    entries.filter_map { |entry| allocate_entry(entry) }
  end

  # Returns danger-claude -P args for the given mappings.
  def self.dc_port_args(mappings)
    mappings.flat_map { |m| ['-P', "#{m[:host_port]}:#{m[:container_port]}"] }
  end

  def self.allocate_entry(entry)
    container_port = entry['port']
    return nil unless container_port

    host_port = find_free_port
    { host_port: host_port, container_port: container_port, command: entry['command'] }
  end
  private_class_method :allocate_entry

  def self.find_free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end
  private_class_method :find_free_port
end
