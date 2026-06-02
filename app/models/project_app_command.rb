# frozen_string_literal: true

# One command row from a project's `app:` block (cf. autodev/docs/autospec.md §A).
#
# `command` is stored as a JSON array verbatim (Docker-CMD style, e.g.
# `["bundle", "install"]`). `port` is only meaningful for `category: 'run'`
# entries that expose a server to the host for Chrome DevTools.
class ProjectAppCommand < ApplicationRecord
  CATEGORY_SETUP = 'setup'
  CATEGORY_TEST  = 'test'
  CATEGORY_LINT  = 'lint'
  CATEGORY_RUN   = 'run'
  CATEGORIES     = [CATEGORY_SETUP, CATEGORY_TEST, CATEGORY_LINT, CATEGORY_RUN].freeze

  belongs_to :project

  validates :category, inclusion: { in: CATEGORIES }
  validates :command, presence: true
  validate :command_must_be_string_array
  validate :port_only_on_run_category

  default_scope -> { order(:category, :position, :id) }

  private

  def command_must_be_string_array
    return if command.is_a?(Array) && !command.empty? && command.all?(String)

    errors.add(:command, 'must be a non-empty array of strings')
  end

  def port_only_on_run_category
    return if port.nil?
    return if category == CATEGORY_RUN

    errors.add(:port, "is only allowed when category is '#{CATEGORY_RUN}'")
  end
end
