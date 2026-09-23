# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'

module Autospec
  # Generates the per-project briefing markdown that the chat system
  # prompt injects so Claude has project-aware context for AutoSpec
  # cadrage. Runs hourly via RefreshProjectBriefingsJob; the chat path
  # is read-only (consumes project.briefing_text whatever its age).
  #
  # Why staging branch specifically: the briefing should reflect what
  # SHIPS to users, not what's been merged to main and waiting for a
  # release. `staging` is the canonical "next deploy" branch in
  # Modulotech projects; if it doesn't exist, fall back to the
  # repo's default branch.
  #
  # Why danger-claude rather than the Anthropic API directly: we want
  # Claude to actually read the code (CLAUDE.md, file structure,
  # recent commits) — the only way to get that without paying chat-
  # turn latency on every CSM message is to do it once an hour in
  # the background with the same containerised Claude Code we use
  # for implementation. Hourly cadence keeps the briefing fresh
  # without slowing down draft creation (which is the friction
  # point we explicitly want to avoid).
  #
  # The class is long because PROMPT is: the spawn plumbing beside it
  # is short, and splitting the prompt away from its only reader would
  # hide what the briefing asks for.
  class ProjectBriefer # rubocop:disable Metrics/ClassLength
    # danger-claude runs through the same spawn as every other child
    # (timeout with a process-group kill, CLEAN_ENV, the exit status as
    # a fourth element) rather than a raw capture3 of its own.
    include ProcessRunner

    # The one error refresh! stores and the job rescues: "this refresh
    # failed for a reason outside autodev". A bug (NoMethodError, a
    # failed update!) is deliberately not one, so it still reaches Solid
    # Queue's failed executions instead of being filed next to network
    # outages (Autodev #117).
    class RefreshFailed < StandardError; end

    # Shallow clone depth — the briefing only needs the latest code,
    # not history. 1 commit is enough for danger-claude to read files
    # but `git log -10` still works (those are reachable from HEAD
    # via the partial clone protocol).
    CLONE_DEPTH = 1

    # Hard timeout on the danger-claude invocation, enforced by
    # ProcessRunner (the previous 5 minutes was declared and never
    # applied). Clone plus danger-claude measured at most 279 s over
    # 713 production runs, so 600 s is about twice the worst case: it
    # catches a hang without failing a refresh that succeeds today. If
    # it times out, the previous briefing stays in place.
    DANGER_CLAUDE_TIMEOUT = 10 * 60

    # How much of a command's output a stored failure keeps.
    DETAIL_LIMIT = 400

    PROMPT = <<~PROMPT
      You are AutoSpec's project-briefing generator.

      Read the codebase in the current working directory and produce
      a concise briefing (30-60 lines of markdown) that gives a
      ticket-drafter the context they need to write specs that fit
      this project.

      What to include, in this order:

      1. **Domain & purpose** — one paragraph. What does this app do,
         for whom, in what business context.
      2. **Stack** — one line per layer (language, framework, key
         libraries, database, deploy target).
      3. **Architecture sketch** — 3-6 bullets. The main modules /
         subsystems and how they relate. Reference real file paths.
      4. **Glossary / lexicon** — domain terms a non-engineer would
         confuse with general English. 5-10 entries, "term — short
         definition".
      5. **Conventions** — naming, branching, testing, style. Anything
         a contributor must follow. Pull from CLAUDE.md if present.
      6. **Recent direction** — `git log -20 --oneline` themes:
         what's moving and what's stable.

      What to avoid:
      - Generic statements ("uses Ruby on Rails for the backend") —
        only write things that distinguish THIS project from any
        random Rails app.
      - Repeating CLAUDE.md verbatim — summarise.
      - Code snippets longer than 3 lines — prefer file paths.

      Output the briefing as raw markdown, no preamble, no postscript.
    PROMPT

    class << self
      # Test seam: when set, every refresh! call invokes this Proc
      # instead of shelling out to danger-claude. Receives the
      # work_dir and the prompt string, returns the briefing markdown
      # (or raises to simulate failure). Mirrors the
      # `Autospec::GitlabImporter.default_client` pattern.
      attr_accessor :stub_invoker
    end

    def initialize(project, config: nil)
      @project = project
      @config  = config
      # ProcessRunner's record buffers. It appends to them on every
      # spawn; the briefer never persists them.
      @dc_stdout = +''
      @dc_stderr = +''
    end

    def refresh!
      Dir.mktmpdir('autospec_briefing_') do |tmp_dir|
        clone_target = File.join(tmp_dir, 'repo')
        clone_into!(clone_target)
        briefing = invoke_danger_claude!(clone_target)
        store_success!(briefing)
      end
    rescue RefreshFailed => e
      store_failure!(e.message)
      raise
    end

    private

    def clone_into!(work_dir)
      branch = pick_branch
      run_git_clone!(work_dir, branch)
    end

    # Try `staging` first; if `git ls-remote` doesn't list it, fall
    # back to whatever HEAD is at the remote (typically `main` or
    # `master`). We don't hard-code the fallback name — `--branch HEAD`
    # would lie about the branch label, so we resolve it via
    # ls-remote --symref.
    #
    # Only a *successful* ls-remote with no output means "no staging
    # branch". A failed one says nothing about the branch — guessing
    # from it cloned `main` on a `master` repository and blamed the
    # branch for what was the network.
    def pick_branch
      out = git!('ls-remote (staging)', 'ls-remote', '--heads', clone_url, 'staging')
      return 'staging' if out.length.positive?

      default_branch
    end

    def default_branch
      out = git!('ls-remote (HEAD)', 'ls-remote', '--symref', clone_url, 'HEAD')
      match = %r{ref: refs/heads/([^\s\t]+)\s+HEAD}.match(out)
      match ? match[1] : 'main'
    end

    def run_git_clone!(work_dir, branch)
      git!("clone (#{branch})", 'clone', '--depth', CLONE_DEPTH.to_s, '--branch', branch, clone_url, work_dir)
    end

    # Through run_cmd_status because it answers `status.success?`:
    # capture3's third value is a Process::Status, truthy even on
    # failure, and reading it as a boolean is how a failed clone once
    # passed for a success and surfaced as an ENOENT with no cause.
    def git!(label, *args)
      out, err, ok = external!("git #{label}") { ShellHelpers.run_cmd_status(['git', *args]) }
      raise RefreshFailed, Redactor.scrub("git #{label} failed: #{head(err)}") unless ok

      out
    end

    def clone_url
      token = config_hash['gitlab_token'].to_s
      base  = config_hash['gitlab_url'].to_s.sub(%r{^https?://}, '')
      raise RefreshFailed, 'gitlab_token missing in Web.config' if token.empty?
      raise RefreshFailed, 'gitlab_url missing in Web.config'   if base.empty?

      "https://oauth2:#{token}@#{base}/#{@project.gitlab_path}.git"
    end

    def invoke_danger_claude!(work_dir)
      return self.class.stub_invoker.call(work_dir, PROMPT) if self.class.stub_invoker

      out, err, ok, status = run_danger_claude(work_dir)
      raise RefreshFailed, Redactor.scrub("danger-claude failed (#{ending(status)}): #{detail(out, err)}") unless ok

      briefing = out.to_s.strip
      raise RefreshFailed, 'danger-claude returned empty output' if briefing.empty?

      briefing
    end

    def run_danger_claude(work_dir)
      external!('danger-claude') do
        run_with_timeout('danger-claude', ['-p', PROMPT], chdir: work_dir,
                                                          label: 'briefing', timeout: DANGER_CLAUDE_TIMEOUT)
      end
    rescue ImplementationError => e
      # ProcessRunner's timeout, already killed and already named.
      raise RefreshFailed, Redactor.scrub(e.message)
    end

    # A spawn that cannot happen at all (binary missing, vanished
    # `chdir:`) is a fact about the machine, not a bug: it becomes a
    # RefreshFailed naming the command, so refresh! stores it and the
    # job moves on to the next project instead of stopping its loop.
    def external!(label)
      yield
    rescue SystemCallError => e
      raise RefreshFailed, Redactor.scrub("#{label} could not run: #{e.message}")
    end

    # Every production failure stored an empty string after the colon:
    # danger-claude wrote nothing on stderr. So say how it ended, and
    # fall back on the end of stdout, where its last words are.
    def ending(status)
      return "exit #{status.exitstatus}" if status&.exitstatus
      return "signal #{status.termsig}" if status&.termsig

      'unknown status'
    end

    def detail(out, err)
      [err, out].each do |stream|
        text = tail(stream)
        return text unless text.empty?
      end
      'no output'
    end

    # Scrub the whole stream, then cut: cutting first can split a
    # credential before its `@`, and URL_CREDENTIALS then misses it.
    def head(text)
      Redactor.scrub(text.to_s)[0, DETAIL_LIMIT]
    end

    def tail(text)
      scrubbed = Redactor.scrub(text.to_s).strip
      scrubbed.length > DETAIL_LIMIT ? scrubbed[-DETAIL_LIMIT..] : scrubbed
    end

    def store_success!(text)
      @project.update!(briefing_text: text, briefing_generated_at: Time.current, briefing_error: nil)
    end

    def store_failure!(message)
      # Keep the previous briefing_text intact — a stale briefing is
      # better than no briefing, and the chat path doesn't care about
      # the age of the row.
      @project.update!(briefing_error: message)
    end

    def config_hash
      @config || (defined?(::Web) && ::Web.respond_to?(:config) && ::Web.config) || {}
    end
  end
end
