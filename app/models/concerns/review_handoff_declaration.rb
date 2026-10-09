# frozen_string_literal: true

# The project's measurement and draw scripts, run on a delivered merge request
# before autodev writes the review labels, the reviewer and the assignee
# (Autodev #90, `PipelineMonitor::ReviewHandoff`). Command arrays, listed in
# `Project::LIST_CONFIG_KEYS` and held to the same shape as every list key by
# `Project#validate_string_arrays`.
module ReviewHandoffDeclaration
  extend ActiveSupport::Concern

  REVIEW_HANDOFF_KEYS = %i[review_size_command review_coverage_command reviewer_draw_command].freeze

  included do
    validate :validate_review_handoff_pairing
  end

  private

  # The draw is routed on the measured size and nothing is written on the
  # merge request without one, so coverage or a draw declared alone would be
  # configuration that silently never runs.
  def validate_review_handoff_pairing
    return if review_size_command.present?

    %i[review_coverage_command reviewer_draw_command].each do |field|
      errors.add(field, 'is set but review_size_command is missing') if public_send(field).present?
    end
  end
end
