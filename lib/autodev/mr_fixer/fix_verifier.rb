# frozen_string_literal: true

class MrFixer
  # How many corrections one fix round is allowed to verify — and therefore how
  # many threads it attempts at all, since a thread it cannot verify is a thread
  # it must not resolve (Autodev #79).
  #
  # 10, from production: over the 94 fix rounds on record the number of
  # unresolved threads runs from 1 to 18 with a mean of 7.6, and 81% of rounds
  # carry 10 or fewer. So the cap is invisible to four rounds in five, and the
  # one in five it does bite is the round nobody wants to pay for twice anyway —
  # 18 threads is 36 danger-claude calls before this change.
  #
  # Read as `@project_config[…] || @config[…] || DEFAULT`, the shape
  # `infra_recheck_max` and `pipeline_watch_max_days` already use. `0` is the
  # sentinel: no verification at all, i.e. the pre-#79 behaviour, and it has to
  # be written down by whoever wants it.
  DEFAULT_FIX_VERIFICATION_MAX = 10

  # The outcome of one targeted verification.
  #
  # `cause` exists because the three ways a correction fails to be verified tell
  # a reader three different things: `:verdict` — the pass looked and says the
  # diff misses the point; `:unchanged` — danger-claude committed nothing, so
  # there is no claim to check; `:unverifiable` — the pass itself could not be
  # performed. They share one consequence (the thread stays open) and must not
  # share one message.
  FixCheck = Data.define(:addressed, :cause, :detail) do
    def self.passed = new(addressed: true, cause: nil, detail: nil)
    def self.rejected(cause, detail = nil) = new(addressed: false, cause: cause, detail: detail)
  end

  # A named defect and the diff that claims to fix it — the pass PowerPanne's own
  # review skill prescribes after its triage, and the one it distinguishes by
  # name from re-running the adversarial pass on a corrected commit. The
  # asymmetry is the point: an adversarial reviewer produces findings on any
  # code and the loop never converges, while "does this diff address this
  # finding" is bounded by construction.
  #
  # Deliberately NOT the session that produced the fix: `run_fix_prompt` resumes
  # one session across a round's threads, and resuming it here would be the
  # defect Autodev #79 is about, one layer down — the same agent correcting and
  # declaring. No `-a mr-fixer` either, whose whole instruction is how to correct.
  module FixVerifier
    private

    def fix_verification_max
      (@project_config['fix_verification_max'] || @config['fix_verification_max'] ||
        DEFAULT_FIX_VERIFICATION_MAX).to_i
    end

    def verify_fixes? = fix_verification_max.positive?

    # What one round is allowed to attempt. The overflow is not "fixed without
    # being verified" — it is not fixed at all, and the next round picks it up
    # exactly as it picks up a thread whose correction failed. Suspending the
    # invariant for the overflow would put the cost bound and the guarantee in
    # competition, and the guarantee is the whole ticket.
    def attempted_this_round(discussions)
      return discussions unless verify_fixes?

      discussions.first(fix_verification_max)
    end

    # Every outcome that is not "the pass looked and said yes" lands on the same
    # side. That is the Autodev #62 direction transposed from a GitLab read to a
    # danger-claude call: the neutral value here is `addressed`, which closes a
    # review thread for good, and a check that could not be performed must not
    # produce it. `RateLimitError` / `AuthenticationError` are deliberately not
    # caught — they are not verdicts about this correction either, and every
    # other `danger_claude_prompt` call site lets them travel to the round's
    # boundary, which parks the row with a retry instead of closing anything.
    #
    # Landing on the same *side* is not landing on the same *cause*, and the two
    # were confused here once (Autodev #79, fix round 2). An empty diff and a
    # `git` that did not answer both used to arrive as `nil` and both were read
    # as `:unchanged` — "the correction changed nothing", a measured fact,
    # imputed to a measurement that never happened. That is the same mistake one
    # level down from the doctrine written above, and it is not cosmetic: every
    # thread of the round takes that path, so the round resolves nothing, the
    # next round finds the identical thread set, `discussion_stagnated?`
    # recognises the signature, and the request is given up on a stagnation that
    # is really a broken work directory. `correction_diff` now raises rather than
    # answering `nil`, so the two cannot merge again.
    def verify_fix(discussion, thread_context, work_dir, base_sha)
      diff = correction_diff(work_dir, base_sha)
      return FixCheck.rejected(:unchanged) if diff.empty?

      contract = run_verification(discussion, thread_context, work_dir, diff)
      return FixCheck.passed if contract.addressed?

      FixCheck.rejected(:verdict, contract.reason)
    rescue GitError, ImplementationError, VerificationContract::InvalidError => e
      FixCheck.rejected(:unverifiable, "#{e.class}: #{e.message[0, 200]}")
    end

    # Deliberately still `nil` on failure rather than raising: this runs *before*
    # the fix, from `fix_single_discussion`, where an exception would escape to
    # `execute_fix_cycle`'s `rescue StandardError` and mark the whole request
    # `error` with a comment blaming the correction. `correction_diff` turns the
    # missing sha into the per-thread outcome instead, which is the granularity
    # the failure actually has.
    def head_sha(work_dir)
      out, _err, ok = run_cmd_status(%w[git rev-parse HEAD], chdir: work_dir)
      ok && !out.empty? ? out : nil
    end

    # What this thread's correction actually changed, and nothing else: the
    # commit `danger_claude_commit` just made, measured from the sha the thread
    # started on. Not `origin/branch..HEAD`, which would carry the whole round.
    #
    # `nil` is not in this method's vocabulary, and that is the whole point
    # (Autodev #79, fix round 2). An **empty String** is an answer — "this
    # correction changed nothing" — and it is the only thing `:unchanged` may
    # ever be built from. Everything else is the *absence* of an answer and
    # raises, so no caller can read it as one: the same rule `GitlabHelpers.answer`
    # states for a GitLab read (Autodev #62), for the same reason — a failing
    # `git` reports a non-zero status and an empty stdout, which is byte-for-byte
    # what "nothing changed" looks like.
    #
    # Both causes raise the same class on purpose. A reader's next move is
    # identical (look at the work directory), so they share `:unverifiable` and
    # its sentence; what differs is the message, and the message is what says
    # which of the two `git` questions went unanswered.
    def correction_diff(work_dir, base_sha)
      raise GitError, 'could not read HEAD before the correction' unless base_sha

      out, err, ok = run_cmd_status(['git', 'diff', "#{base_sha}..HEAD"], chdir: work_dir)
      raise GitError, "git diff #{base_sha}..HEAD failed: #{err[0, 200]}" unless ok

      out
    end

    def run_verification(discussion, thread_context, work_dir, diff)
      diff_path = verification_diff_path(discussion)
      contract_path = verification_contract_path(discussion)
      File.write(diff_path, diff)
      FileUtils.rm_f(contract_path)
      danger_claude_prompt(work_dir, verification_prompt(thread_context, diff_path, contract_path),
                           label: '-p (verification)')
      read_verification_contract(contract_path)
    ensure
      FileUtils.rm_f(diff_path)
      FileUtils.rm_f(contract_path)
    end

    def read_verification_contract(path)
      raise VerificationContract::InvalidError, "contract file #{path} was not written" unless File.exist?(path)

      VerificationContract.parse(File.read(path))
    end

    # Both files live under /tmp, never inside the clone: `dc_global_args` mounts
    # `/tmp` into the container, and a file written in the work directory would
    # be swept into the *next* thread's `danger-claude -c` commit.
    def verification_path_stem(discussion)
      id = discussion[:id].to_s.gsub(/[^0-9A-Za-z]/, '_')[0, 40]
      "/tmp/autodev_fixcheck_#{@project_path.tr('/', '_')}_#{id}"
    end

    def verification_contract_path(discussion) = "#{verification_path_stem(discussion)}.json"

    def verification_diff_path(discussion) = "#{verification_path_stem(discussion)}.diff"

    def verification_prompt(thread_context, diff_path, contract_path)
      <<~PROMPT
        Tu verifies une correction. Tu ne la produis pas, tu ne la modifies pas, et tu
        ne touches a aucun fichier du depot.

        ## Le constat de review d'origine

        #{thread_context}

        ## La correction proposee

        Le diff complet de la correction est dans `#{diff_path}`. Lis-le entierement.

        ## La seule question

        Ce diff traite-t-il le constat ci-dessus ? Reponds sur ce seul critere. Ne
        cherche pas d'autres defauts et ne juge pas la qualite generale du code : un
        constat nomme se verifie, une passe de revue sur du code corrige ne converge pas.

        Reponds `not_addressed` si le diff ne touche pas le sujet du constat, s'il
        supprime le symptome sans traiter la cause, ou si tu ne peux pas etablir le lien
        entre les deux. Sinon `addressed`.

        Ecris ta reponse dans #{contract_path}, et rien d'autre nulle part :

        {"verdict":"addressed|not_addressed","reason":"une phrase"}
      PROMPT
    end
  end
end
