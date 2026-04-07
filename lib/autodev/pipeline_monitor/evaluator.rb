# frozen_string_literal: true

class PipelineMonitor
  # Claude-based pipeline failure evaluation.
  module Evaluator
    private

    def evaluate_code_related(work_dir, eval_context)
      prompt = build_eval_prompt(eval_context)
      out = danger_claude_prompt(work_dir, prompt, label: '-p (pipeline eval)')
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
