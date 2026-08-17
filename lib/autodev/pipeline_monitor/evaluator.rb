# frozen_string_literal: true

class PipelineMonitor
  # Claude-based pipeline failure evaluation: run it, parse it, and say what its
  # answer means.
  #
  # The last part used to live in `FailureHandler` (Autodev #62). Splitting one
  # evaluation across two modules is part of how constat 3 stayed hidden: the
  # module named after the evaluation held "did it parse?" while the *meaning* of
  # a nil — "Claude said no" versus "Claude never answered" — was decided a file
  # away, where the difference reads as one `unless` next to another.
  module Evaluator
    # Dedups the recurring "evaluating" line in the activity note: an issue stuck
    # in checking_pipeline would otherwise append one per poll cycle and blow past
    # GitLab's 1M-char note cap. Sibling of FailureHandler's two patterns.
    PIPELINE_EVAL_PATTERN = /— :mag: Evaluat/i

    private

    def evaluate_with_claude(issue, work_dir, job_entries)
      log "Issue ##{issue.issue_iid}: pre-triage uncertain, evaluating with Claude..."
      log_activity(issue, :pipeline_evaluating, replace_pattern: PIPELINE_EVAL_PATTERN)
      eval_result = evaluate_code_related(work_dir, build_eval_context(job_entries))
      interpret_eval_result(issue, eval_result)
    end

    # Both branches return nil — "no fix to dispatch" — but for reasons that are
    # not the same kind of thing, and Autodev #62 (constat 3) is that the caller
    # could not tell them apart either.
    #
    # `code_related: false` is a **verdict**: Claude read the logs and says the
    # failure is not the branch's, so waiting is the answer and the age bound may
    # count this poll — a fortnight of that is exactly what Autodev #53 exists to
    # stop. A missing result is **no verdict at all**: danger-claude crashed, timed
    # out, or answered something `parse_eval_response` could not read. The poll then
    # ends normally having concluded nothing, so it raises the per-poll flag and the
    # bound stands down for this cycle — the fourth path of the Autodev #56 family,
    # identified during its implementation and left out of scope then.
    def interpret_eval_result(issue, eval_result)
      unless eval_result
        poll_inconclusive!(:pipeline_evaluation_failed)
        log "Issue ##{issue.issue_iid}: evaluation failed, staying in checking_pipeline"
        return nil
      end

      unless eval_result['code_related']
        log "Issue ##{issue.issue_iid}: non-code failure, staying in checking_pipeline"
        return nil
      end

      eval_result['explanation'] || 'Aucune explication fournie'
    end

    def evaluate_code_related(work_dir, eval_context)
      prompt = build_eval_prompt(eval_context)
      out = danger_claude_prompt(work_dir, prompt, label: '-p (pipeline eval)', model: 'haiku')
      parse_eval_response(out)
    end

    def build_eval_prompt(eval_context)
      <<~PROMPT
        Tu dois analyser un echec de pipeline CI/CD et determiner s'il est lie au code ou non.

        ## Jobs en echec

        #{eval_context}

        Lis chaque fichier de log reference ci-dessus.

        ## Instructions de reponse

        Reponds UNIQUEMENT avec un objet JSON valide (sans bloc de code markdown) :
        { "code_related": true/false, "explanation": "explication courte" }

        - `code_related: true` si l'echec vient du code (test, compilation, lint, etc.)
        - `code_related: false` si infrastructure (timeout reseau, service indisponible, quota, etc.)
      PROMPT
    end

    def parse_eval_response(out)
      json_match = out.match(/\{[^{}]*"code_related"\s*:\s*(true|false)[^{}]*\}/m)
      return nil unless json_match

      JSON.parse(json_match[0])
    rescue JSON::ParserError
      nil
    end
  end
end
