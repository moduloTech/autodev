# frozen_string_literal: true

# Locale-aware message templates for GitLab issue comments.
# Each key maps to one notify_issue call site across the processors.
module Locales
  TEMPLATES = {
    fr: {
      processing_started: ':robot: %{tag} : traitement en cours...',
      mr_created: ':white_check_mark: %{tag} : MR creee : %{mr_url}',
      error_generic: ':x: %{tag} : echec — %{error}',
      spec_unclear_header: ':thinking: %{tag} : la specification necessite des precisions avant implementation.',
      spec_unclear_footer: "Merci de repondre a ces questions dans les commentaires. L'implementation reprendra automatiquement.",
      question_answered_header: ':mag: %{tag} : reponse a la question',
      question_answered_footer: "_Cette reponse a ete generee automatiquement par analyse du codebase. N'hesitez pas a demander des precisions._",
      mr_fix_success: ':wrench: %{tag} : %{count} commentaire(s) de review corrige(s) sur %{mr_url} (round %{round})',
      mr_fix_error: ':x: %{tag} : echec correction MR — %{error}',
      pipeline_canceled: ':warning: %{tag} : le pipeline de %{mr_url} est %{status}. Intervention manuelle requise.',
      pipeline_no_failed_jobs: ":warning: %{tag} : le pipeline de %{mr_url} a echoue mais aucun job en echec n'a ete trouve. Intervention manuelle requise.",
      pipeline_infra_pretriage: ":warning: %{tag} : le pipeline de %{mr_url} echoue pour une raison d'infrastructure (pre-triage). Intervention manuelle requise.\n\n> %{explanation}",
      pipeline_eval_failed: ":warning: %{tag} : le pipeline de %{mr_url} a echoue et l'evaluation automatique n'a pas abouti. Intervention manuelle requise.",
      pipeline_non_code: ":warning: %{tag} : le pipeline de %{mr_url} echoue pour une raison hors code. Intervention manuelle requise.\n\n> %{explanation}",
      pipeline_max_rounds: ":warning: %{tag} : le pipeline de %{mr_url} echoue a cause du code mais le nombre maximum de rounds de fix est atteint. Intervention manuelle requise.\n\n> %{explanation}",
      pipeline_fix_error: ':x: %{tag} : echec de la correction du pipeline — %{error}',
      pipeline_fix_success: ':wrench: %{tag} : correction du pipeline appliquee sur %{mr_url} — %{count} job(s) corrige(s) (round %{round})'
    },
    en: {
      processing_started: ':robot: %{tag}: processing in progress...',
      mr_created: ':white_check_mark: %{tag}: MR created: %{mr_url}',
      error_generic: ':x: %{tag}: failed — %{error}',
      spec_unclear_header: ':thinking: %{tag}: the specification needs clarification before implementation.',
      spec_unclear_footer: 'Please answer these questions in the comments. Implementation will resume automatically.',
      question_answered_header: ':mag: %{tag}: answer to the question',
      question_answered_footer: '_This answer was generated automatically by analyzing the codebase. Feel free to ask for more details._',
      mr_fix_success: ':wrench: %{tag}: %{count} review comment(s) fixed on %{mr_url} (round %{round})',
      mr_fix_error: ':x: %{tag}: MR fix failed — %{error}',
      pipeline_canceled: ':warning: %{tag}: pipeline for %{mr_url} is %{status}. Manual intervention required.',
      pipeline_no_failed_jobs: ':warning: %{tag}: pipeline for %{mr_url} failed but no failed jobs were found. Manual intervention required.',
      pipeline_infra_pretriage: ":warning: %{tag}: pipeline for %{mr_url} failed due to infrastructure (pre-triage). Manual intervention required.\n\n> %{explanation}",
      pipeline_eval_failed: ':warning: %{tag}: pipeline for %{mr_url} failed and automatic evaluation could not determine the cause. Manual intervention required.',
      pipeline_non_code: ":warning: %{tag}: pipeline for %{mr_url} failed for a non-code reason. Manual intervention required.\n\n> %{explanation}",
      pipeline_max_rounds: ":warning: %{tag}: pipeline for %{mr_url} failed due to code but the maximum number of fix rounds has been reached. Manual intervention required.\n\n> %{explanation}",
      pipeline_fix_error: ':x: %{tag}: pipeline fix failed — %{error}',
      pipeline_fix_success: ':wrench: %{tag}: pipeline fix applied on %{mr_url} — %{count} job(s) fixed (round %{round})'
    }
  }.freeze

  def self.t(key, locale: :fr, **vars)
    template = TEMPLATES.dig(locale, key) || TEMPLATES.dig(:fr, key) || key.to_s
    template % vars
  end
end
