# frozen_string_literal: true

class IssueProcessor
  # Low-level helpers for building clone URLs and commands.
  module CloneHelpers
    private

    def build_clone_url
      uri = URI.parse(@gitlab_url)
      host_port = uri.port && ![80, 443].include?(uri.port) ? "#{uri.host}:#{uri.port}" : uri.host
      "#{uri.scheme}://oauth2:#{@token}@#{host_port}/#{@project_path}.git"
    end

    def build_clone_cmd(clone_url, work_dir)
      depth = @project_config['clone_depth'] || 1
      sparse = @project_config['sparse_checkout']
      target = @project_config['target_branch']

      cmd = %w[git clone]
      cmd += ['--depth', depth.to_s] if depth.positive?
      cmd += ['--branch', target] if target
      cmd += ['--filter=blob:none', '--sparse'] if sparse.is_a?(Array) && sparse.any?
      cmd + [clone_url, work_dir]
    end

    def setup_sparse_checkout(work_dir)
      sparse = @project_config['sparse_checkout']
      return unless sparse.is_a?(Array) && sparse.any?

      log "Setting up sparse checkout: #{sparse.join(', ')}"
      run_cmd(%w[git sparse-checkout set] + sparse, chdir: work_dir)
    end
  end
end
