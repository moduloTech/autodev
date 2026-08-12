# frozen_string_literal: true

require_relative 'locales'

# Type-and-range declarations for every numeric setting autodev reads
# (Autodev #58).
#
# `Config::INTEGER_FIELDS` used to answer two different questions with one
# list: "coerce this to an Integer" and "reject it unless it is > 0". That
# conflation is why `pipeline_watch_max_days` had to be left out of the list
# entirely — 0 is a meaningful value there (it disables the age bound) and the
# list had no way to say "0 is fine, but a string is not". The consequence was
# no coercion and no validation at all on a last-resort safety net: a
# non-numeric value in config.yml read as `.to_i` → 0 → bound disabled, in
# silence. Symmetrically, `mr_review_timeout` was validated as "positive" with
# no ceiling, so a dropped-digit typo (86400000 for 86400) widened
# `HealthReport`'s dormant-detection window to years and switched off the two
# mechanisms that catch a dead worker.
#
# Here the two questions are separate:
#
#   * the **type** question is `NumericSettings.integer` — it either returns an
#     Integer or nil. It never turns garbage into 0;
#   * the **range** question is the `Spec` a field declares. `min: 0` is how a
#     setting says "0 is a sentinel", which is a statement about the range and
#     no longer doubles as permission for anything that coerces to 0.
#
# Declaring a future numeric setting is one line in `SPECS`. Every layer reads
# the same declaration: `ConfigValidator` (globals in config.yml),
# `ProjectValidator` (a YAML `projects:` entry), `Project` (the DB columns and
# therefore the dashboard's config form), and `bin/autodev` (the boot warning
# over the configs the poller will actually run with).
module NumericSettings
  # A closed, inclusive range for one field. `cover?` is only ever asked about
  # a value that already answered the type question.
  Spec = Data.define(:field, :min, :max) do
    def cover?(value) = value.between?(min, max)
  end

  # One rejected value, as reported by `.audit`. `project` is the GitLab path
  # the setting was found on; `value` is the value exactly as configured — the
  # boot warning has to print what the operator typed, not a coercion of it.
  Violation = Data.define(:project, :field, :value, :reason)

  # Floor and ceiling shared by the three worker timeouts (`dc_timeout`,
  # `post_completion_timeout`, `mr_review_timeout`).
  #
  # Floor 60 s: no danger-claude call, mr-review run or post-completion command
  # has ever finished in under a minute, so nothing legitimate sits below it and
  # a dropped digit (360 → 36) is caught.
  #
  # Ceiling 21_600 s (6 h): 6× the largest of the three baked defaults (3600)
  # and 8× the longest successful mr-review on record (2641 s, Autodev #54), so
  # it cannot reject a configuration anyone would choose. What it buys is the
  # property Autodev #58 is about: `HealthReport#longest_worker_timeout` feeds
  # `stuck_active_after = max(configured or 7200, 2 × longest timeout)`, so the
  # dormant-detection window — which is also `dispatch_dormant_audit`'s safety
  # bound and the "Issues bloquées" card — is now capped at 12 h. With no
  # ceiling, the ticket's 86_400_000 pushed that same window to ~5.5 years.
  TIMEOUT_MIN = 60
  TIMEOUT_MAX = 21_600

  # A day, in seconds: the ceiling for every "spacing between two attempts"
  # setting. Above a day the value is a typo, not a policy.
  DAY = 86_400

  # Ceiling for the "how many times" counters. At production's 120 s poll
  # interval, 100 identical rounds is ~3.3 h — still a bail-out, which is the
  # point of those counters.
  ROUNDS_MAX = 100

  # field => [min, max]. `min: 0` marks the two settings where 0 is a
  # meaningful value rather than an invalid one.
  SPECS = {
    # Global-only (Config::DEFAULTS).
    'poll_interval' => [10, DAY],
    'max_workers' => [1, 64],
    'pickup_delay' => [1, DAY],
    # Global + per-project override.
    'dc_timeout' => [TIMEOUT_MIN, TIMEOUT_MAX],
    'max_retries' => [1, ROUNDS_MAX],
    'retry_backoff' => [1, DAY],
    'stagnation_threshold' => [1, ROUNDS_MAX],
    # Per-project only.
    'clone_depth' => [0, 10_000], # 0 = full clone
    'post_completion_timeout' => [TIMEOUT_MIN, TIMEOUT_MAX],
    'mr_review_timeout' => [TIMEOUT_MIN, TIMEOUT_MAX],
    # Safety nets, read as `@project_config[…] || @config[…] || DEFAULT`.
    # `pipeline_watch_max_days` accepts 0 (disables the age bound) but not a
    # string — the whole of CONSTAT 2. Ceiling 365: a year is already far past
    # the six-week "nobody will look at this again" horizon Autodev #53 set,
    # and it keeps the bound finite.
    'pipeline_watch_max_days' => [0, 365],
    'infra_recheck_max' => [1, ROUNDS_MAX],
    'infra_recheck_backoff' => [1, DAY],
    'dormant_audit_max' => [1, ROUNDS_MAX],
    'dormant_audit_backoff' => [1, DAY],
    # Pre-#47 names of the two above, still read by DormantAudit.
    'error_recheck_max' => [1, ROUNDS_MAX],
    'error_recheck_backoff' => [1, DAY]
  }.to_h { |field, (min, max)| [field, Spec.new(field: field, min: min, max: max)] }.freeze

  MESSAGE_KEYS = { not_an_integer: :cli_numeric_setting_not_a_number,
                   out_of_range: :cli_numeric_setting_out_of_range }.freeze
  private_constant :MESSAGE_KEYS

  def self.fields = SPECS.keys

  def self.spec(field) = SPECS[field.to_s]

  # The type question, and nothing else. Returns an Integer or nil — never 0
  # for a value that is not a number, which is the bug this module exists to
  # close. Strings are read in base 10 explicitly: `Integer('010')` would
  # otherwise be 8.
  def self.integer(raw)
    case raw
    when Integer then raw
    when Float then raw.to_i if raw.finite? && raw.to_i == raw
    when String then Integer(raw.strip, 10, exception: false)
    end
  end

  # nil when the value is acceptable (or the field declares no range),
  # :not_an_integer when it fails the type question, :out_of_range when it
  # passes the type question and fails the range one. A nil value counts as
  # :not_an_integer — callers that treat an *absent* setting as legitimate skip
  # it before asking.
  def self.violation(field, raw)
    declared = spec(field)
    return nil if declared.nil?

    value = integer(raw)
    return :not_an_integer if value.nil?

    :out_of_range unless declared.cover?(value)
  end

  # Walks a list of YAML-shaped per-project configs (`Project.runtime_configs`
  # at boot) and returns one Violation per rejected value. Absent and nil
  # settings are legitimate — they mean "fall back to the global default".
  def self.audit(project_configs)
    Array(project_configs).flat_map { |config| audit_config(config) }
  end

  def self.audit_config(project_config)
    return [] unless project_config.is_a?(Hash)

    path = project_config['path'].to_s
    SPECS.each_key.filter_map do |field|
      raw = project_config[field]
      next if raw.nil?

      reason = violation(field, raw)
      Violation.new(project: path, field: field, value: raw, reason: reason) if reason
    end
  end
  private_class_method :audit_config

  # The operator-facing line for one Violation (the boot warning). Localized:
  # it names the project, the field, the value as configured, and the range.
  #
  # The interpolation variable is `project`, not `scope`: `:scope` is a reserved
  # I18n option, so passing it makes I18n read it as a lookup namespace instead
  # of a placeholder and the message degrades silently to the bare key.
  def self.describe(violation, locale: :fr)
    declared = spec(violation.field)
    vars = { project: violation.project, field: violation.field, value: violation.value.inspect,
             min: declared.min, max: declared.max }
    Locales.t(MESSAGE_KEYS.fetch(violation.reason), locale: locale, **vars)
  end

  # Message for a ConfigError raised on a config.yml value. English, like every
  # other ConfigError in the codebase — it is read in a terminal by whoever is
  # editing the file, and `bin/autodev` prints it as "Config error: …".
  def self.config_error_message(field, raw, scope: nil)
    declared = spec(field)
    "#{"#{scope}: " if scope}'#{field}' must be an integer between " \
      "#{declared.min} and #{declared.max}, got: #{raw.inspect}"
  end

  # ActiveModel error message for a column whose value is out of range. The
  # dashboard re-renders it through `t_web` (Web::Views::ProjectEdit keys off
  # the error's :out_of_range type); this is the fallback every other consumer
  # of `errors.full_messages` gets — console, rake, `--status`.
  def self.range_message(field)
    declared = spec(field)
    "must be an integer between #{declared.min} and #{declared.max}"
  end
end
