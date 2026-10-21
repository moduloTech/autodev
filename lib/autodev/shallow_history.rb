# frozen_string_literal: true

# Gives a shallow clone the history a rebase needs: a merge base between the
# branch and its target (Autodev #138, adversarial review). Mixed into
# `RepoRebaser`; expects `run_cmd_status`.
module ShallowHistory
  # Rounds of `deepen_step` before giving up on deepening and fetching the whole
  # history: 4 × 500 covers the 865 commits powerpanne 12935 was behind.
  DEEPEN_ROUNDS = 4

  private

  # How many commits one deepening round asks for, on each side. A method so
  # that a test can make a short history behave like a long one.
  def deepen_step = 500

  # A rebase with no merge base is not a rebase (Autodev #138, adversarial
  # review). Every clone here is `--depth 1` unless the project says otherwise —
  # neither production project does — so the branch arrives as one commit with no
  # parent, and deepening the *target* alone never reaches the fork point. git
  # then replays the branch tip as a root commit, and every file the target
  # changed since the fork comes back as an add/add conflict: measured on a
  # `file://` clone (the transport honours `--depth`, as https does — a plain
  # path does not), a branch that only added `feat.rb` conflicted on `shared.rb`,
  # which only the target had touched. That fed danger-claude a conflict on files
  # the branch never touched and, since #138, would hand the line back on them.
  #
  # So both sides are deepened together until git finds the fork point, and past
  # `DEEPEN_ROUNDS` the history is fetched whole. If even that leaves no merge
  # base the fetch did not land or the histories are unrelated: neither is a
  # conflict a human can resolve from a list of files, so it is a `GitError`,
  # which every path already answers as a failure of its own.
  def ensure_merge_base!(work_dir, branch, base)
    refspecs = [base, branch].map { |ref| "+refs/heads/#{ref}:refs/remotes/origin/#{ref}" }
    DEEPEN_ROUNDS.times do
      return if merge_base?(work_dir, base)
      break unless shallow?(work_dir)

      run_cmd_status(['git', 'fetch', "--deepen=#{deepen_step}", 'origin', *refspecs], chdir: work_dir)
    end
    run_cmd_status(['git', 'fetch', '--unshallow', 'origin', *refspecs], chdir: work_dir) if shallow?(work_dir)
    return if merge_base?(work_dir, base)

    raise GitError, "no merge base between #{branch} and origin/#{base}, even with the full history"
  end

  def merge_base?(work_dir, base)
    _, _, ok = run_cmd_status(['git', 'merge-base', 'HEAD', "origin/#{base}"], chdir: work_dir)
    ok
  end

  def shallow?(work_dir)
    out, = run_cmd_status(%w[git rev-parse --is-shallow-repository], chdir: work_dir)
    out.strip == 'true'
  end
end
