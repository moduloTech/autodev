# frozen_string_literal: true

# Locale-aware message templates for GitLab issue comments.
# Each key maps to one notify_issue call site across the processors.
module Locales
  TEMPLATES = {
    fr: {
      processing_started: ':robot: %<tag>s : traitement en cours...',
      mr_created: ':white_check_mark: %<tag>s : MR creee : %<mr_url>s',
      error_generic: ':x: %<tag>s : echec — %<error>s',
      spec_unclear_header: ':thinking: %<tag>s : la specification necessite des precisions avant implementation.',
      spec_unclear_footer: 'Merci de repondre a ces questions dans les commentaires. ' \
                           "L'implementation reprendra automatiquement.",
      question_answered_header: ':mag: %<tag>s : reponse a la question',
      question_answered_footer: '_Cette reponse a ete generee automatiquement par analyse du codebase. ' \
                                "N'hesitez pas a demander des precisions._",
      mr_fix_success: ':wrench: %<tag>s : %<count>s commentaire(s) de review corrige(s) ' \
                      'sur %<mr_url>s (round %<round>s)',
      mr_fix_error: ':x: %<tag>s : echec correction MR — %<error>s',
      pipeline_canceled: ':warning: %<tag>s : le pipeline de %<mr_url>s est %<status>s. Intervention manuelle requise.',
      pipeline_no_failed_jobs: ':warning: %<tag>s : le pipeline de %<mr_url>s a echoue ' \
                               "mais aucun job en echec n'a ete trouve. Intervention manuelle requise.",
      pipeline_infra_pretriage: ':warning: %<tag>s : le pipeline de %<mr_url>s echoue pour une raison ' \
                                "d'infrastructure (pre-triage). Intervention manuelle requise.\n\n> %<explanation>s",
      pipeline_eval_failed: ':warning: %<tag>s : le pipeline de %<mr_url>s a echoue et ' \
                            "l'evaluation automatique n'a pas abouti. Intervention manuelle requise.",
      pipeline_non_code: ':warning: %<tag>s : le pipeline de %<mr_url>s echoue pour une raison ' \
                         "hors code. Intervention manuelle requise.\n\n> %<explanation>s",
      pipeline_max_rounds: ':warning: %<tag>s : le pipeline de %<mr_url>s echoue a cause du code mais le nombre ' \
                           "maximum de rounds de fix est atteint. Intervention manuelle requise.\n\n> %<explanation>s",
      pipeline_fix_error: ':x: %<tag>s : echec de la correction du pipeline — %<error>s',
      pipeline_fix_success: ':wrench: %<tag>s : correction du pipeline appliquee sur ' \
                            '%<mr_url>s — %<count>s job(s) corrige(s) (round %<round>s)'
    },
    en: {
      processing_started: ':robot: %<tag>s: processing in progress...',
      mr_created: ':white_check_mark: %<tag>s: MR created: %<mr_url>s',
      error_generic: ':x: %<tag>s: failed — %<error>s',
      spec_unclear_header: ':thinking: %<tag>s: the specification needs clarification before implementation.',
      spec_unclear_footer: 'Please answer these questions in the comments. Implementation will resume automatically.',
      question_answered_header: ':mag: %<tag>s: answer to the question',
      question_answered_footer: '_This answer was generated automatically by analyzing the codebase. ' \
                                'Feel free to ask for more details._',
      mr_fix_success: ':wrench: %<tag>s: %<count>s review comment(s) fixed on %<mr_url>s (round %<round>s)',
      mr_fix_error: ':x: %<tag>s: MR fix failed — %<error>s',
      pipeline_canceled: ':warning: %<tag>s: pipeline for %<mr_url>s is %<status>s. Manual intervention required.',
      pipeline_no_failed_jobs: ':warning: %<tag>s: pipeline for %<mr_url>s failed but no failed jobs ' \
                               'were found. Manual intervention required.',
      pipeline_infra_pretriage: ':warning: %<tag>s: pipeline for %<mr_url>s failed due to infrastructure ' \
                                "(pre-triage). Manual intervention required.\n\n> %<explanation>s",
      pipeline_eval_failed: ':warning: %<tag>s: pipeline for %<mr_url>s failed and automatic evaluation ' \
                            'could not determine the cause. Manual intervention required.',
      pipeline_non_code: ':warning: %<tag>s: pipeline for %<mr_url>s failed for a non-code reason. ' \
                         "Manual intervention required.\n\n> %<explanation>s",
      pipeline_max_rounds: ':warning: %<tag>s: pipeline for %<mr_url>s failed due to code but the maximum ' \
                           "number of fix rounds has been reached. Manual intervention required.\n\n> %<explanation>s",
      pipeline_fix_error: ':x: %<tag>s: pipeline fix failed — %<error>s',
      pipeline_fix_success: ':wrench: %<tag>s: pipeline fix applied on %<mr_url>s — ' \
                            '%<count>s job(s) fixed (round %<round>s)'
    }
  }.freeze

  def self.t(key, locale: :fr, **vars)
    template = TEMPLATES.dig(locale, key) || TEMPLATES.dig(:fr, key) || key.to_s
    template % vars
  end
end
