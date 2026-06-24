# frozen_string_literal: true

# A named ticket template a project defines for AutoSpec (task #14).
#
# `body` is the markdown structure AutoSpec is told to follow when the
# CSM drafts a ticket of this kind on the project — e.g. an "évolution"
# template with "Localisation / Contexte / Résultat attendu / …" sections.
# Replaces the manual copy-paste of a template into the chat: the
# structure is injected into the AutoSpec system prompt (see
# `Autospec::SystemPrompt`). A project may have several (one per kind);
# `slug` is the stable per-project key, `name` the display label.
class ProjectTicketTemplate < ApplicationRecord
  belongs_to :project

  validates :name, presence: true
  validates :body, presence: true
  validates :slug, presence: true,
                   uniqueness: { scope: :project_id },
                   format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                             message: 'must be lowercase alphanumeric with single hyphens' }

  before_validation :derive_slug_from_name, if: -> { slug.blank? && name.present? }

  default_scope -> { order(:position, :id) }

  private

  # Mirror Project's slug derivation style: lowercase, accent-insensitive,
  # non-alphanumerics collapsed to single hyphens (e.g. "Évolution" → "evolution").
  def derive_slug_from_name
    self.slug = name.to_s.unicode_normalize(:nfkd).encode('ASCII', replace: '')
                    .downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
  end
end
