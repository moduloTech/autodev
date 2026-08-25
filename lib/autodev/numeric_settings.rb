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
#
# rubocop:disable Metrics/ModuleLength -- most of the body is the two declaration
# tables, and their length is data: this module exists so that every numeric
# setting is visible in one place, so splitting the registry across files to
# satisfy a line count would cost exactly the property it is for. Same call as
# `Config`, the sibling table module.
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
    # How many corrections one MR fix round verifies, and therefore how many
    # threads it attempts (Autodev #79). Accepts 0 — the sentinel that switches
    # the verification off and restores the pre-#79 "fix, resolve, push" — but
    # not a string, for the same reason `pipeline_watch_max_days` does not: a
    # value read as `.to_i` → 0 would disable a safety net in silence.
    'fix_verification_max' => [0, ROUNDS_MAX],
    'infra_recheck_max' => [1, ROUNDS_MAX],
    'infra_recheck_backoff' => [1, DAY],
    'dormant_audit_max' => [1, ROUNDS_MAX],
    'dormant_audit_backoff' => [1, DAY],
    # Pre-#47 names of the two above, still read by DormantAudit.
    'error_recheck_max' => [1, ROUNDS_MAX],
    'error_recheck_backoff' => [1, DAY]
  }.to_h { |field, (min, max)| [field, Spec.new(field: field, min: min, max: max)] }.freeze

  # The `monitoring:` block, one level down from the flat globals above.
  #
  # It needs its own table because its keys are nested, not because it deserves
  # different treatment — the point is that it gets the *same* treatment. All five
  # of these were read as `(value || DEFAULT).to_i`, and `.to_i` on a non-number is
  # 0, which is a meaningful value for every one of them. So a typo did not fail,
  # it reconfigured the setting in silence:
  #
  #   * `review_failure_window_seconds` → 0 s: the rolling window asks for events
  #     newer than "now", counts none, and Autodev #60's mr-review alert answers
  #     `:ok` forever;
  #   * `review_failure_threshold` → 0: `count >= 0` is always true, so the same
  #     check answers `:warn` permanently;
  #   * the other three are saved only by their floor semantics (`max(configured,
  #     derived)`), which is luck rather than design.
  #
  # Ranges: a window under a minute or over a day is a typo either way. The
  # threshold accepts 1 ("warn on the first failing ticket" is a deliberate
  # setting) but not 0. `activity_event_retention_seconds` keeps a wide ceiling —
  # a long retention is a legitimate forensic choice, and a value *under* the
  # safety window is ignored rather than rejected (see ActivityEventJanitor).
  MONITORING_SPECS = {
    'review_failure_window_seconds' => [60, DAY],
    'review_failure_threshold' => [1, ROUNDS_MAX],
    'poll_stale_factor' => [1, ROUNDS_MAX],
    'stuck_active_after_seconds' => [60, DAY],
    'activity_event_retention_seconds' => [60, 365 * DAY]
  }.to_h { |field, (min, max)| [field, Spec.new(field: field, min: min, max: max)] }.freeze

  MONITORING_FIELDS = MONITORING_SPECS.keys.freeze

  MESSAGE_KEYS = { not_an_integer: :cli_numeric_setting_not_a_number,
                   out_of_range: :cli_numeric_setting_out_of_range }.freeze
  private_constant :MESSAGE_KEYS

  def self.fields = SPECS.keys

  def self.spec(field) = SPECS[field.to_s]

  def self.monitoring_spec(field) = MONITORING_SPECS[field.to_s]

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
    check(spec(field), raw)
  end

  # Same question, against the `monitoring:` table. An absent setting is
  # legitimate — it means "use the default" — so nil is not a violation here,
  # unlike in `violation`, where the caller has already decided the key is set.
  def self.monitoring_violation(field, raw)
    return nil if raw.nil?

    check(monitoring_spec(field), raw)
  end

  def self.check(declared, raw)
    return nil if declared.nil?

    value = integer(raw)
    return :not_an_integer if value.nil?

    :out_of_range unless declared.cover?(value)
  end
  private_class_method :check

  # The read-side companion to the boot validation: coerce a `monitoring:` value
  # and fall back to `default` unless it is both a number and in range.
  #
  # Belt and braces, deliberately. `ConfigValidator` already refuses to boot the
  # supervisor on a bad value, but `HealthReport` and `ActivityEventJanitor` are
  # also built from hand-made hashes by `bin/rails runner`, by the test suite and
  # by anything that never calls `validate_globals!`. There the fallback must be
  # the documented default — which is protective — and never 0, which for these
  # five settings is a silently different configuration rather than an error.
  def self.monitoring_integer(config, field, default:)
    raw = config.is_a?(Hash) ? config.dig('monitoring', field) : nil
    return default if monitoring_violation(field, raw) || raw.nil?

    integer(raw)
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
    range_error_message(spec(field), field, raw, scope: scope)
  end

  # Same sentence for a `monitoring:` key, qualified so the operator knows which
  # block to open — the field names are only unique within it.
  def self.monitoring_error_message(field, raw)
    range_error_message(monitoring_spec(field), "monitoring.#{field}", raw)
  end

  def self.range_error_message(declared, label, raw, scope: nil)
    "#{"#{scope}: " if scope}'#{label}' must be an integer between " \
      "#{declared.min} and #{declared.max}, got: #{raw.inspect}"
  end
  private_class_method :range_error_message

  # ActiveModel error message for a column whose value is out of range. The
  # dashboard re-renders it through `t_web` (Web::Views::ProjectEdit keys off
  # the error's :out_of_range type); this is the fallback every other consumer
  # of `errors.full_messages` gets — console, rake, `--status`.
  def self.range_message(field)
    declared = spec(field)
    "must be an integer between #{declared.min} and #{declared.max}"
  end
end
# rubocop:enable Metrics/ModuleLength
