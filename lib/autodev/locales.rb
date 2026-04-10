# frozen_string_literal: true

require_relative 'locales/activity'

# Locale-aware message templates for GitLab issue comments.
# Each key maps to one notify_issue call site across the processors.
module Locales
  NOTIFICATION_TEMPLATES = {
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
      pipeline_fix_error: ':x: %<tag>s : echec de la correction du pipeline — %<error>s',
      pipeline_fix_success: ':wrench: %<tag>s : correction du pipeline appliquee sur ' \
                            '%<mr_url>s — %<count>s job(s) corrige(s) (round %<round>s)',
      review_limit_reached: ':warning: %<tag>s : la limite de review (3 tours) est atteinte pour %<mr_url>s. ' \
                            'Les discussions non resolues restantes necessitent une intervention manuelle.',
      stagnation_pipeline: ':warning: %<tag>s : stagnation detectee — les memes jobs echouent de maniere repetee ' \
                           'sur %<mr_url>s. Intervention manuelle requise.',
      stagnation_discussions: ':warning: %<tag>s : stagnation detectee — les memes discussions restent non resolues ' \
                              'sur %<mr_url>s. Intervention manuelle requise.',
      unassigned_stop: ':stop_sign: %<tag>s : desassigne, arret du travail en cours.',
      done_nominal: ":checkered_flag: %<tag>s : j'ai termine mon travail sur ce ticket !\n\n" \
                    ':arrow_right: **Vous souhaitez que je corrige ou ameliore quelque chose ?** ' \
                    'Pas de souci ! Remettez le label _%<label_todo>s_, reassignez-moi sur le ticket, ' \
                    "et je m'en occupe.\n\n" \
                    ':arrow_right: **Tout est bon ?** Vous pouvez passer a la suite.',
      done_question: ":checkered_flag: %<tag>s : j'ai termine mon investigation !\n\n" \
                     ':arrow_right: **Vous souhaitez creuser davantage ou passer a une implementation ?** ' \
                     'Laissez un commentaire pour me guider, remettez le label _%<label_todo>s_, reassignez-moi, ' \
                     "et c'est parti."
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
      pipeline_fix_error: ':x: %<tag>s: pipeline fix failed — %<error>s',
      pipeline_fix_success: ':wrench: %<tag>s: pipeline fix applied on %<mr_url>s — ' \
                            '%<count>s job(s) fixed (round %<round>s)',
      review_limit_reached: ':warning: %<tag>s: review limit (3 rounds) reached for %<mr_url>s. ' \
                            'Remaining unresolved discussions require manual intervention.',
      stagnation_pipeline: ':warning: %<tag>s: stagnation detected — the same jobs keep failing ' \
                           'on %<mr_url>s. Manual intervention required.',
      stagnation_discussions: ':warning: %<tag>s: stagnation detected — the same discussions remain unresolved ' \
                              'on %<mr_url>s. Manual intervention required.',
      unassigned_stop: ':stop_sign: %<tag>s: unassigned, stopping work in progress.',
      done_nominal: ":checkered_flag: %<tag>s: I'm done working on this ticket!\n\n" \
                    ':arrow_right: **Want me to fix or improve something?** ' \
                    'No problem! Put the _%<label_todo>s_ label back, reassign me to the ticket, ' \
                    "and I'll take care of it.\n\n" \
                    ':arrow_right: **Everything looks good?** You can move on to the next step.',
      done_question: ":checkered_flag: %<tag>s: I've finished my investigation!\n\n" \
                     ':arrow_right: **Want to dig deeper or move on to an implementation?** ' \
                     'Leave a comment to guide me, put the _%<label_todo>s_ label back, reassign me, ' \
                     "and I'm on it."
    }
  }.freeze

  TEMPLATES = NOTIFICATION_TEMPLATES.merge(ACTIVITY_TEMPLATES) { |_key, notif, act| notif.merge(act) }.freeze

  def self.t(key, locale: :fr, **vars)
    template = TEMPLATES.dig(locale, key) || TEMPLATES.dig(:fr, key) || key.to_s
    template % vars
  end
end
