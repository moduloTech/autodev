# frozen_string_literal: true

require_relative 'stagnation_checker'
require_relative 'fix_prompts'
require_relative 'fix_verifier'

class MrFixer
  # Orchestrates the clone-fix-push cycle and error handling for MR discussion fixes.
  # Expects the including class to provide DangerClaudeRunner methods and DiscussionFormatter.
  module FixCycle # rubocop:disable Metrics/ModuleLength
    include StagnationChecker
    include FixPrompts
    include FixVerifier

    private

    # Sibling of `FailureHandler#attempt_fix`, and the same exception (Autodev
    # #67): the clone, the rebase, danger-claude and the push are genuinely this
    # round's failures, but the prompt-context read underneath
    # `prepare_fix_environment` is not. It travels to `MrFixer#fix`, which leaves
    # the row in `fixing_discussions` for `dispatch_discussions` to re-enqueue.
    def execute_fix_cycle(issue, discussions)
      work_dir = "/tmp/autodev_mrfix_#{@project_path.gsub('/', '_')}_#{issue.issue_iid}"
      run_fix_cycle(issue, discussions, work_dir)
    rescue ApiUnavailableError
      raise
    rescue RateLimitError => e
      handle_rate_limit(issue, e)
    rescue StandardError => e
      handle_fix_error(issue, e)
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end

    # The base is resolved once and handed to both users of it (Autodev #91): the
    # rebase, and the hunk `DiscussionFormatter` quotes to danger-claude. They used
    # to disagree — the rebase took the configuration, the hunk took
    # `default_branch(work_dir)` — so the correction was made on a tree rebased on
    # one branch while the finding was illustrated with a diff against another.
    # Resolved once, after the clone and before the rebase, they cannot.
    def run_fix_cycle(issue, discussions, work_dir)
      @fix_issue = issue
      branch = issue.branch_name
      clone_and_checkout(work_dir, branch)
      base = target_branch_for(work_dir, issue.mr_iid)
      rebase_branch_on_target(work_dir, branch, base: base)
      env = prepare_fix_environment(work_dir, issue.issue_iid, issue.mr_iid, base)

      resolved = Array(fix_each_discussion(discussions, work_dir, branch, issue.mr_iid, env))

      return finalize_no_commits(issue, discussions) unless new_commits?(work_dir, branch)

      push_fixes(work_dir, branch)
      finalize_success(issue, discussions, resolved)
    end

    # The GitLab read first, the local work after: the read is the only step here
    # that can abort the round (Autodev #67), so there is no point writing skills
    # into a clone we are about to delete.
    def prepare_fix_environment(work_dir, iid, mr_iid, base)
      full_context = GitlabHelpers.fetch_full_context(
        @client, @project_path, iid,
        mr_iid: mr_iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir
      )
      skills_result = SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)
      build_fix_env(skills_result, full_context, work_dir, iid, base)
    end

    def build_fix_env(skills_result, full_context, work_dir, iid, base)
      ss_dir = ScreenshotUploader.screenshot_dir(@project_path, iid)
      { skills_line: SkillsInjector.skills_instruction(skills_result[:all_skills]),
        target_branch: base, full_context: full_context,
        app_section: AppInstructions.prompt_section(
          @project_config, port_mappings: @port_mappings || [], screenshot_dir: ss_dir
        ),
        agent: detect_agent(work_dir, 'mr-fixer') }
    end

    # Answers with the discussions this round actually resolved, which since
    # Autodev #79 is a subset of the ones it attempted rather than all of them.
    def fix_each_discussion(discussions, work_dir, branch, mr_iid, env)
      @mr_fix_session_id = nil
      attempted = attempted_this_round(discussions)
      note_deferred(discussions.size - attempted.size)
      attempted.each_with_index.filter_map do |discussion, idx|
        log "Fixing discussion #{idx + 1}/#{attempted.size}: #{discussion[:title]}"
        log_activity(@fix_issue, :discussion_fixing, title: discussion[:title])
        fix_single_discussion(discussion, work_dir, branch, mr_iid, env)
      end
    end

    def note_deferred(count)
      return unless count.positive?

      log "Deferring #{count} discussion(s) to the next round (fix_verification_max=#{fix_verification_max})"
      log_activity(@fix_issue, :discussions_deferred, count: count)
    end

    # The resolution is the claim that the review point is dealt with, and since
    # Autodev #79 it is only ever made behind a verdict something other than the
    # fixing session produced. Returns the discussion when the thread was
    # resolved, nil when it was left open for the next round.
    def fix_single_discussion(discussion, work_dir, branch, mr_iid, env)
      thread_context = format_discussion(discussion, work_dir: work_dir, target_branch: env[:target_branch])
      base_sha = head_sha(work_dir) if verify_fixes?
      run_fix_prompt(thread_context, work_dir, branch, env)
      danger_claude_commit(work_dir, resume: @mr_fix_session_id)
      check = verify_fixes? ? verify_fix(discussion, thread_context, work_dir, base_sha) : FixCheck.passed
      return record_unverified(discussion, check) unless check.addressed

      resolve_discussion(mr_iid, discussion[:id])
      discussion
    end

    # One consequence, three sentences: which of them a reader gets decides
    # whether they go and look at the correction, at the review comment, or at
    # danger-claude. Written out rather than dispatched on a variable key, so
    # `test/i18n_derived_keys_test.rb` reads all three off the call sites.
    def record_unverified(discussion, check)
      log "Discussion #{discussion[:id]} left unresolved (#{check.cause}): #{check.detail}"
      case check.cause
      when :unchanged
        log_activity(@fix_issue, :discussion_unchanged, title: discussion[:title])
      when :verdict
        log_activity(@fix_issue, :discussion_unverified, title: discussion[:title], reason: check.detail)
      else
        log_activity(@fix_issue, :discussion_unverifiable, title: discussion[:title], error: check.detail)
      end
      nil
    end

    def run_fix_prompt(thread_context, work_dir, branch, env)
      if @mr_fix_session_id
        danger_claude_prompt(work_dir, build_followup_prompt(thread_context),
                             agent: env[:agent], resume: @mr_fix_session_id)
      else
        run_first_fix(thread_context, work_dir, branch, env)
      end
      @mr_fix_session_id = @last_session_id
    end

    def run_first_fix(thread_context, work_dir, branch, env)
      extra = @project_config['extra_prompt']
      with_context_file(work_dir, branch, env[:full_context]) do |context_filename|
        prompt = build_fix_prompt(context_filename, thread_context, env[:skills_line], extra, env[:app_section])
        danger_claude_prompt(work_dir, prompt, agent: env[:agent])
      end
    end

    def new_commits?(work_dir, branch)
      out, _err, ok = run_cmd_status(['git', 'log', "origin/#{branch}..HEAD", '--oneline'], chdir: work_dir)
      ok && !out.empty?
    end

    # The round that changed nothing, and the one the stagnation guard exists for
    # (Autodev #99). It used to return here without going near
    # `discussion_stagnated?`, which lives in `finalize_success` — so the guard was
    # only ever reached by the rounds that had converged, and a loop producing no
    # commit at all was unbounded. Powerpanne 15205 ran eighteen such rounds over
    # sixteen hours with `count` stuck at 1.
    #
    # `discussion_stagnated?` both counts and decides, so both halves were missing.
    # Autodev #71's rule is untouched: this IS a completed attempt — the threads
    # were read, the corrections were attempted, danger-claude answered — it simply
    # produced nothing, which is the fact the signature records.
    def finalize_no_commits(issue, discussions)
      log 'No new commits after fixing, skipping push'
      issue.update(fix_round: issue.fix_round + 1, pipeline_retrigger_count: 0,
                   discussion_fix_round: issue.discussion_fix_round + 1)
      return if discussion_stagnated?(issue, discussions)

      issue.discussions_fixed!
    end

    def push_fixes(work_dir, branch)
      push_with_lease_fallback(work_dir, branch)
    end

    # The stagnation signature is still taken over the threads the round *found*,
    # not over the ones it resolved: "the same discussions are still open" is the
    # question it answers, and a round that resolved none of them is exactly the
    # case it exists to end.
    def finalize_success(issue, discussions, resolved)
      ScreenshotUploader.process(client: @client, project_path: @project_path,
                                 iid: issue.issue_iid, logger: @logger)
      round = issue.fix_round + 1
      issue.update(fix_round: round, pipeline_retrigger_count: 0,
                   discussion_fix_round: issue.discussion_fix_round + 1,
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      return if discussion_stagnated?(issue, discussions)

      complete_discussion_fix(issue, resolved.size, round)
    end

    def complete_discussion_fix(issue, count, round)
      issue.discussions_fixed!
      report_round(issue, count, round)
      log_activity(issue, :pipeline_watch)
      log "MR !#{issue.mr_iid}: resolved #{count} discussion(s) (round #{round})"
    end

    # What the round says about itself, decided **once** (Autodev #79, fix round
    # 2). It used to be decided twice: `announce_fix_success` withheld the GitLab
    # comment when nothing was resolved, and the `:discussions_fixed` activity
    # entry was written three lines below with no condition at all — and
    # `ActivityLogger.post` writes that entry into the activity note **on the
    # same GitLab issue**. The sentence the guard existed to suppress was posted
    # anyway, by the other sink. Two guards were needed for one rule, only one
    # was written, and there is now one place where the rule can be read.
    #
    # A round that resolved nothing is not silent either. "This round could not
    # resolve anything" is worth reading — it is what makes the run of identical
    # rounds before a `stagnation_discussions` give-up legible instead of
    # sudden — but it gets its own key, so neither a reader nor a counter can
    # take it for a delivery.
    def report_round(issue, count, round)
      return log_activity(issue, :discussions_none_resolved, round: round) unless count.positive?

      notify_localized(issue.issue_iid, :mr_fix_success, count: count, mr_url: issue.mr_url, round: round)
      log_activity(issue, :discussions_fixed, count: count, round: round)
    end
  end
end
