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
  class ProjectBriefer
    class RefreshFailed < StandardError; end

    # Shallow clone depth — the briefing only needs the latest code,
    # not history. 1 commit is enough for danger-claude to read files
    # but `git log -10` still works (those are reachable from HEAD
    # via the partial clone protocol).
    CLONE_DEPTH = 1

    # Hard timeout on the danger-claude invocation. The briefing
    # prompt is short and the model has all the context locally —
    # 5 minutes is generous. If it times out, the previous briefing
    # stays in place.
    DANGER_CLAUDE_TIMEOUT = 5 * 60

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
    def pick_branch
      out, _err, ok = Open3.capture3('git', 'ls-remote', '--heads', clone_url, 'staging')
      return 'staging' if ok && out.to_s.strip.length.positive?

      default_branch
    end

    def default_branch
      out, _err, ok = Open3.capture3('git', 'ls-remote', '--symref', clone_url, 'HEAD')
      return 'main' unless ok

      match = %r{ref: refs/heads/([^\s\t]+)\s+HEAD}.match(out.to_s)
      match ? match[1] : 'main'
    end

    def run_git_clone!(work_dir, branch)
      cmd = ['git', 'clone', '--depth', CLONE_DEPTH.to_s, '--branch', branch, clone_url, work_dir]
      _out, err, ok = Open3.capture3(*cmd)
      raise RefreshFailed, "git clone (#{branch}) failed: #{err.to_s[0, 400]}" unless ok
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

      out, err, status = Open3.capture3('danger-claude', '-p', PROMPT,
                                        chdir: work_dir, stdin_data: '')
      raise RefreshFailed, "danger-claude failed: #{err.to_s[0, 400]}" unless status.success?

      briefing = out.to_s.strip
      raise RefreshFailed, 'danger-claude returned empty output' if briefing.empty?

      briefing
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
