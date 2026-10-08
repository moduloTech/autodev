# frozen_string_literal: true

require 'json'
require 'shellwords'
require 'tempfile'

class PipelineMonitor
  # The measuring half of `ReviewHandoff` (Autodev #90): the project's own
  # scripts, run inside the container autodev already runs the project in —
  # danger-claude's, through `danger-claude -s` — on a clone of the merge
  # request's branch. Nothing here writes to GitLab.
  #
  # Three facts were measured before any of this was written, on a local
  # danger-claude 0.5.10 image and a `--depth 1` clone of a powerpanne/core
  # merge request, and each one is a line below:
  #
  # - the clone holds the head only, and both size and coverage run
  #   `git diff <base> <head>` → `fetch_diff_ends`;
  # - the container's Ruby reads US-ASCII without a locale (`mr_size` died on
  #   `"\xC3" on US-ASCII`) → `LANG=C.UTF-8`;
  # - git refuses a mount owned by another uid ("dubious ownership"), and
  #   `mr_size` then fails with `Could not access '<sha>'` → `safe.directory`
  #   through `GIT_CONFIG_*`, the command-line scope git honours for it.
  module ReviewHandoffScripts
    ENV_MOUNT = '/autodev/handoff.env'
    # A whole-element placeholder: `--red` when the measured zone is red, gone
    # otherwise — `reviewer_draw` takes a bare flag.
    RED_FLAG = '%{red_flag}' # rubocop:disable Style/FormatStringToken
    RED_ARGUMENT = '--red'

    # What one script answered. `exit_code` is nil for a process ended by a
    # signal; `json` is nil when no stdout line parsed as a JSON object.
    ScriptResult = Struct.new(:exit_code, :json, :stderr) do
      def success? = exit_code&.zero? && !json.nil?
    end

    private

    # `%{name}` placeholders, substituted per element; `RED_FLAG` is the one
    # that may remove its element.
    def handoff_argv(template, vars, red: false)
      template.filter_map do |element|
        next (red ? RED_ARGUMENT : nil) if element == RED_FLAG

        vars.reduce(element) { |arg, (name, value)| arg.gsub("%{#{name}}", value.to_s) }
      end
    end

    def clone_for_handoff(work_dir, issue, refs)
      clone_and_checkout(work_dir, issue.branch_name)
      fetch_diff_ends(work_dir, refs)
    end

    # Only what is missing: a full clone (`clone_depth: 0`) already holds both,
    # and a `--depth 1` fetch there would make it shallow for nothing.
    def fetch_diff_ends(work_dir, refs)
      missing = refs.values.uniq.reject do |sha|
        run_cmd_status(['git', 'cat-file', '-e', "#{sha}^{commit}"], chdir: work_dir)[2]
      end
      run_cmd(['git', 'fetch', '--depth', '1', 'origin', *missing], chdir: work_dir) if missing.any?
    end

    # The credential reaches the script through a 0600 file mounted read-only,
    # never argv: argv is readable by `ps` for the whole run (Autodev #10, #80).
    # danger-claude has no `-e`, hence the file and the `set -a` source.
    def run_handoff_script(work_dir, argv)
      Tempfile.create(['autodev-handoff', '.env']) do |file|
        file.write(handoff_env)
        file.flush
        args = ['-v', "#{file.path}:#{ENV_MOUNT}:ro", '-s', handoff_shell(argv)]
        out, err, _ok, status = run_with_timeout('danger-claude', args, chdir: work_dir,
                                                                        label: "-s #{argv.join(' ')}")
        ScriptResult.new(status&.exitstatus, last_json_object(out), err.to_s)
      end
    end

    def handoff_shell(argv)
      "set -a && . #{ENV_MOUNT} && set +a && exec #{argv.map { |arg| Shellwords.escape(arg) }.join(' ')}"
    end

    def handoff_env
      { 'GITLAB_TOKEN' => @token, 'GITLAB_HOST' => gitlab_host, 'LANG' => 'C.UTF-8',
        'GIT_CONFIG_COUNT' => '1', 'GIT_CONFIG_KEY_0' => 'safe.directory', 'GIT_CONFIG_VALUE_0' => '*' }
        .map { |name, value| "#{name}=#{Shellwords.escape(value.to_s)}\n" }.join
    end

    def gitlab_host
      uri = URI.parse(@gitlab_url.to_s)
      uri.port && ![80, 443].include?(uri.port) ? "#{uri.host}:#{uri.port}" : uri.host.to_s
    end

    # The scripts print one JSON object; the container's entrypoint may print
    # around it, so the last line that parses as an object is the answer.
    def last_json_object(out)
      out.to_s.lines.reverse_each do |line|
        parsed = parse_json_line(line)
        return parsed if parsed.is_a?(Hash)
      end
      nil
    end

    def parse_json_line(line)
      JSON.parse(line.strip)
    rescue JSON::ParserError
      nil
    end

    # The last stderr line, scrubbed and short: what the script said about why
    # it failed, fit for an activity note on the ticket.
    def script_reason(result)
      line = result.stderr.lines.map(&:strip).reject(&:empty?).last
      text = line || "exit #{result.exit_code.inspect}"
      Redactor.scrub(text)[0, 300]
    end
  end
end
