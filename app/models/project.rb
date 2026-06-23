# frozen_string_literal: true

# A GitLab project tracked by Autodev (cf. autodev/docs/autospec.md §A).
#
# Step 2: empty during phase B. Phase C's `autodev:migrate_projects_from_yaml`
# rake (autospec §H) populates this from `~/.autodev/config.yml`'s `projects:`
# block, after which the legacy YAML branch in `lib/autodev/poller.rb` is
# deleted.
class Project < ApplicationRecord
  VALID_LOCALES = %w[fr en].freeze

  has_many :app_commands, class_name: 'ProjectAppCommand', dependent: :destroy
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :owners, -> { where(project_memberships: { role: ProjectMembership::ROLE_OWNER }) },
           through: :project_memberships, source: :user
  has_many :autospec_drafts, dependent: :destroy

  validates :gitlab_path, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  validates :default_locale, inclusion: { in: VALID_LOCALES }

  # -- Per-project config (task #9 phase 1) --
  #
  # These mirror lib/autodev/project_validator.rb so the DB rejects the same
  # shapes the YAML validator did. All fields are optional (a project may
  # configure none of them and fall back to the global defaults).
  POSITIVE_INT_FIELDS = %i[dc_timeout max_retries retry_backoff stagnation_threshold
                           post_completion_timeout].freeze
  # "Advanced" keys columnized in phase 2 (were YAML-only in phase 1).
  STRING_CONFIG_FIELDS = %i[model effort implementer_agent test_writer_agent mr_fixer_agent].freeze
  BOOLEAN_CONFIG_FIELDS = %i[parallel_agents split_implementation].freeze

  validates(*POSITIVE_INT_FIELDS, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true)
  validates :clone_depth, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  # `presence: true, allow_nil: true` = "if set, must not be blank" (rejects ""
  # / whitespace but lets an unset field through). The boolean columns are
  # type-cast by AR, so a NULL stays nil and only true/false survive.
  validates(*STRING_CONFIG_FIELDS, presence: true, allow_nil: true)
  validates(*BOOLEAN_CONFIG_FIELDS, inclusion: { in: [true, false] }, allow_nil: true)
  validate :validate_label_workflow
  validate :validate_string_arrays
  validate :validate_post_completion_pairing

  # Rebuilds the YAML-shaped per-project config hash the runtime expects
  # (IssueProcessJob#lookup_project_config). Phase 1 doesn't read this yet —
  # it's the seam the read-path cutover (phase 2) will switch onto. Only
  # present (non-nil/non-empty) keys are emitted, so it layers cleanly over
  # the global defaults exactly like a sparse YAML entry did. `app:` is
  # reconstructed from project_app_commands.
  def to_project_config
    cfg = { 'path' => gitlab_path }
    SCALAR_CONFIG_KEYS.each { |k| add_present(cfg, k.to_s, public_send(k)) }
    LIST_CONFIG_KEYS.each { |k| add_present(cfg, k.to_s, public_send(k)) }
    app = app_config_hash
    cfg['app'] = app unless app.empty?
    cfg
  end

  SCALAR_CONFIG_KEYS = %i[target_branch label_doing label_done extra_prompt dc_timeout
                          max_retries retry_backoff stagnation_threshold clone_depth
                          post_completion_timeout model effort parallel_agents
                          split_implementation implementer_agent test_writer_agent
                          mr_fixer_agent].freeze
  LIST_CONFIG_KEYS = %i[labels_todo sparse_checkout post_completion].freeze
  LABEL_FIELDS = %i[labels_todo label_doing label_done].freeze

  # Editable per-project config fields grouped by input type. Single source
  # of truth for both the dashboard edit form (Web::Views::ProjectEdit, which
  # renders an input per field) and the controller param normalizer
  # (ProjectsController#project_config_params, which casts each group). The
  # boolean group is BOOLEAN_CONFIG_FIELDS and the array group LIST_CONFIG_KEYS
  # (both above). `app:` (project_app_commands) is structured/nested and is
  # edited separately — it's not part of this set (task #9 phase 3).
  CONFIG_INTEGER_FIELDS = (POSITIVE_INT_FIELDS + %i[clone_depth]).freeze
  CONFIG_STRING_FIELDS = (SCALAR_CONFIG_KEYS - CONFIG_INTEGER_FIELDS - BOOLEAN_CONFIG_FIELDS).freeze

  # The per-project runtime configs to discover and operate on (task #9
  # phase 4): every DB row is authoritative (#to_project_config), unioned with
  # any YAML `projects:` entry not yet imported into the DB — the same
  # DB-then-YAML precedence IssueProcessJob#lookup_project_config uses, so a
  # project added to the YAML before the next `autodev:migrate_projects_from_yaml`
  # still polls, while a config whose projects are all in the DB no longer
  # needs the YAML block at all. `yaml_projects` is `config['projects']`.
  def self.runtime_configs(yaml_projects)
    db_configs = all.map(&:to_project_config)
    known = db_configs.map { |c| c['path'] }
    db_configs + Array(yaml_projects).reject { |c| known.include?(c['path']) }
  end

  private

  def add_present(cfg, key, value)
    cfg[key] = value unless blank_config?(value)
  end

  # { 'setup' => [[...]], 'run' => [{ 'command' => [...], 'port' => N }] }
  def app_config_hash
    app_commands.group_by(&:category).transform_values { |cmds| serialize_category(cmds) }
  end

  def serialize_category(cmds)
    sorted = cmds.sort_by(&:position)
    return sorted.map(&:command) unless sorted.first&.category == 'run'

    sorted.map { |c| run_entry(c) }
  end

  def run_entry(cmd)
    entry = { 'command' => cmd.command }
    entry['port'] = cmd.port if cmd.port
    entry
  end

  def validate_label_workflow
    present = LABEL_FIELDS.reject { |f| blank_config?(public_send(f)) }
    return if present.empty?

    missing = LABEL_FIELDS - present
    errors.add(:base, "incomplete label workflow, missing: #{missing.join(', ')}") if missing.any?
    errors.add(:labels_todo, 'must be a non-empty array') unless labels_todo.is_a?(Array) && labels_todo.any?
  end

  def blank_config?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end

  def validate_string_arrays
    { labels_todo: labels_todo, sparse_checkout: sparse_checkout, post_completion: post_completion }.each do |f, v|
      next if v.nil?
      next if v.is_a?(Array) && v.any? && v.all?(String)

      errors.add(f, 'must be a non-empty array of strings')
    end
  end

  def validate_post_completion_pairing
    return unless post_completion_timeout.present? && post_completion.blank?

    errors.add(:post_completion_timeout, 'is set but post_completion is missing')
  end
end
