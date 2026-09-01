# frozen_string_literal: true

# Configuration loading, validation, and CLI argument parsing for autodev.
module Config # rubocop:disable Metrics/ModuleLength
  CONFIG_DIR  = File.expand_path('~/.autodev')
  CONFIG_PATH = File.join(CONFIG_DIR, 'config.yml')
  DEFAULT_DB  = File.join(CONFIG_DIR, 'autodev.db')

  TEMPLATE = <<~YAML
    # autodev configuration
    # See: https://github.com/moduloTech/autodev

    gitlab_url: https://gitlab.example.com
    gitlab_token: glpat-xxxxxxxxxxxxxxxxxxxx   # or set GITLAB_API_TOKEN env var
    # mr_review_token: glpat-yyyyyyyyyyyyyyyyyyyy
    #   Optional. The GitLab credential autodev hands to the `mr-review` binary
    #   (exported as GITLAB_API_TOKEN in that child process only, never in argv).
    #   Unset, mr-review shares `gitlab_token` above. Set it only to keep the two
    #   apart on purpose -- and then it is watched: the poll cycle probes it
    #   whenever at least one project still reviews through the binary, and
    #   /admin/health warns when GitLab rejects it (Autodev #80).
    poll_interval: 300                          # seconds between poll cycles
    max_workers: 3                              # concurrent worker threads
    log_dir: ~/.autodev/logs                       # log directory (default: ~/.autodev/logs)
    log_level: INFO                                # DEBUG, INFO, WARN, ERROR (default: INFO)
    web: { port: 4567, locale: fr, bind: '127.0.0.1' }  # embedded web UI; bind: 0.0.0.0 or NetBird IP to expose
    # Health/monitoring (see docs/observability.md). Unauthenticated /healthz
    # endpoints for external probes (Datadog, BetterStack). Optional token gate.
    # monitoring: { token: null, poll_stale_factor: 3 }  # poll stale after factor × poll_interval

    # Microsoft 365 SSO credentials (Entra ID / Azure AD). Required as of
    # v1.0.0-alpha.7 — without these the gated dashboard can't complete
    # the sign-in handshake. Env vars (`AZURE_AD_CLIENT_ID`,
    # `AZURE_AD_CLIENT_SECRET`, `AZURE_AD_TENANT_ID`) override the values
    # here when set; `tenant_id: common` lets any work/school account in.
    # azure:
    #   client_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    #   client_secret: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    #   tenant_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx


    # Projects are managed in the database (task #9): add and configure them
    # from the dashboard (Projets → Nouveau projet), where every per-project
    # option (labels, target_branch, app:, danger-claude overrides, …) is
    # edited per field. A legacy `projects:` block here still works as a
    # one-time seed — run `bin/rails autodev:migrate_projects_from_yaml` to
    # import it — but it is deprecated and no longer required.
  YAML

  DEFAULTS = {
    'gitlab_url' => nil,
    'gitlab_token' => nil,
    # The credential `mr-review` runs with, when it is deliberately not
    # autodev's own (Autodev #80). nil means "share `gitlab_token`", which is
    # what `mr_review_credential` resolves and what the review step exports.
    'mr_review_token' => nil,
    'poll_interval' => 300,
    'max_workers' => 3,
    'dc_timeout' => 1800,
    'max_retries' => 1,
    'retry_backoff' => 10,
    'pickup_delay' => 600,
    'stagnation_threshold' => 5,
    # Absolute age bound on a pipeline watch, in days (Autodev #53). Nothing
    # else bounds one: stagnation detection is fed only from the red branch, so
    # a pipeline that is never `failed` — manual, canceled, skipped — polls
    # forever. 0 disables the bound.
    #
    # 14 days: above the longest legitimate human absence (a two-week holiday, a
    # shutdown week with a weekend either side), far below the "nobody will look
    # at this again" horizon the ticket sets at six weeks, and far above the
    # bounds that already cover the diagnosable cases (stagnation resolves a red
    # loop in ~25 min, infra recheck in ~5 h) — a safety net must only fire on
    # what the specific mechanisms cannot see. Read by
    # PipelineMonitor::WatchBound, which does not restate the number.
    'pipeline_watch_max_days' => 14,
    'log_dir' => File.join(CONFIG_DIR, 'logs'),
    'log_level' => 'INFO',
    'projects' => [],
    'web' => { 'port' => 4567, 'locale' => 'fr', 'bind' => '127.0.0.1' },
    # Health/monitoring surface (cf. docs/observability.md). `token` (nil =
    # open, matching the 127.0.0.1/NetBird trust model) optionally gates the
    # unauthenticated /healthz endpoints. `poll_stale_factor` × poll_interval
    # is when a missing poller heartbeat flips the health check to "down".
    'monitoring' => { 'token' => nil, 'poll_stale_factor' => 3 }
  }.freeze

  # Baked default for the per-project `post_completion_timeout`, in seconds.
  # Deliberately a standalone constant rather than a DEFAULTS key: it has no
  # global form (there is no `post_completion` outside a project). It lives here
  # because Autodev::HealthReport sizes the stuck-issues window on it (Autodev
  # #50) and must not have to load the PipelineMonitor tree to read it.
  POST_COMPLETION_TIMEOUT = 300

  # Baked default for the per-project `mr_review_timeout`, in seconds. Sized on
  # production data rather than symmetry with dc_timeout: the longest successful
  # mr-review on record took 2641s (Autodev #54).
  MR_REVIEW_TIMEOUT = 3600

  # Where the credential `mr-review` runs with comes from, in the order autodev
  # resolves it (Autodev #80). Sharing is the default: an operator who does
  # nothing gets one token for both tools, and the separation the second key
  # allows is a decision written into autodev's own configuration rather than a
  # file left behind in another tool's directory -- which is how the revoked
  # token of April 2026 went four months without being noticed.
  MR_REVIEW_TOKEN_KEYS = %w[mr_review_token gitlab_token].freeze

  ENV_MAPPING = {
    'GITLAB_API_TOKEN' => 'gitlab_token',
    'GITLAB_URL' => 'gitlab_url'
  }.freeze

  # Global keys no longer read from config.yml. The tunables among them
  # (dc_timeout / max_retries / retry_backoff / stagnation_threshold) keep
  # applying through their per-project overrides and the baked DEFAULTS;
  # `pickup_delay` falls back to its default; `database_url` is vestigial (AR
  # uses config/database.yml). Setting any of these in YAML — or `web.enabled`
  # — is ignored and emits a deprecation warning.
  IGNORED_GLOBAL_FIELDS = %w[dc_timeout max_retries retry_backoff
                             stagnation_threshold pickup_delay database_url].freeze

  # The numeric globals DEFAULTS always supplies, so an absent or nil value is
  # itself a fault rather than "not configured". Everything about *what* an
  # acceptable value is — the type and the range — lives in `NumericSettings`
  # (Autodev #58); this list only answers "must this key be present?".
  #
  # `pipeline_watch_max_days` is deliberately not here even though DEFAULTS
  # carries it: hand-built config hashes (the CLI's own tests, and any caller
  # that validates a partial hash) predate it, and its declared range already
  # covers it whenever it *is* set.
  REQUIRED_NUMERIC_GLOBALS = %w[poll_interval max_workers dc_timeout max_retries retry_backoff
                                pickup_delay stagnation_threshold].freeze

  # Per-project config keys that now live in the DB (task #9 phase 2) and are
  # read from there at runtime (IssueProcessJob#lookup_project_config). Setting
  # one under `projects:` in config.yml still works — the value seeds the DB via
  # `autodev:migrate_projects_from_yaml` and is the runtime fallback for a
  # project with no DB row yet — but it's deprecated and will stop being read
  # once the YAML `projects:` block is removed (task #9 phase 4). `path` is the
  # project identity, not config, so it's excluded.
  DB_BACKED_PROJECT_FIELDS = %w[target_branch labels_todo label_doing label_done label_attention extra_prompt
                                dc_timeout max_retries retry_backoff stagnation_threshold clone_depth
                                sparse_checkout post_completion post_completion_timeout mr_review_timeout
                                model effort parallel_agents split_implementation implementer_agent
                                test_writer_agent mr_fixer_agent review_skill app].freeze
  VALID_LOG_LEVELS = %w[DEBUG INFO WARN ERROR].freeze

  # Single source of truth for the effective retry budget (Autodev #34).
  #
  # `max_retries` counts RETRIES, not total attempts: a budget of N allows a
  # row whose `retry_count` has reached N to be retried once more, and only
  # N+1 to be terminal. Every comparison against it therefore uses `<=`
  # (`retry_count <= max_retries`), not `<`.
  #
  # Resolution order is per-project override → global → baked DEFAULT. Note
  # that a *global* `max_retries` in config.yml is ignored with a deprecation
  # warning (IGNORED_GLOBAL_FIELDS), so in practice it's the per-project
  # override or the DEFAULT — the `config` argument stays because callers hold
  # merged hashes that legitimately carry it.
  #
  # This exists because the former call sites each carried their own fallback
  # and silently disagreed: `|| 3` in IssueProcessor::ErrorHandler, none at
  # all in PollDispatcher (so `nil.to_i` → 0, which would disable retries
  # outright rather than fall back to anything).
  def self.max_retries(project_config, config = nil)
    value = project_config&.[]('max_retries') || config&.[]('max_retries') || DEFAULTS['max_retries']
    value.to_i
  end

  # The credential `mr-review` runs with and the key that supplied it, as
  # `[token, key]` -- nil when autodev's configuration declares neither
  # (Autodev #80). One definition for both readers: the review step, which
  # exports it into that child's environment, and `Autodev::MrReviewTokenProbe`,
  # which asks GitLab whether it is still accepted and records the key's *name*.
  #
  # A present-and-blank value is a typo, not a separation, so it falls through --
  # the same reading `review_skill` gets at every one of its call sites.
  def self.mr_review_credential(config)
    MR_REVIEW_TOKEN_KEYS.each do |key|
      value = (config || {})[key].to_s.strip
      return [value, key] unless value.empty?
    end
    nil
  end

  # The token alone, for the caller that only has to hand it over.
  def self.mr_review_token(config) = mr_review_credential(config)&.first

  def self.load(cli_overrides = {})
    config_path = cli_overrides.delete('config_path') || CONFIG_PATH
    config = DEFAULTS.dup
    yaml = parse_yaml(config_path)
    merge_yaml!(config, yaml)
    merge_env!(config)
    cli_overrides.each { |k, v| config[k] = v unless v.nil? }
    config['_config_path'] = config_path
    coerce_numeric_settings!(config)
    warn_ignored!(yaml)
    config
  end

  # Returns true when the project uses the label workflow (all 5 label fields configured).
  # Only checks labels_todo presence — the other 4 fields are guaranteed by validate_projects!
  # which must be called at startup before any label_workflow? check.
  def self.label_workflow?(project_config)
    project_config['labels_todo'].is_a?(Array) && project_config['labels_todo'].any?
  end

  # Returns true when any project has app.run entries with exposed ports,
  # meaning Chrome DevTools must be launched for screenshot support.
  def self.chrome_devtools_needed?(config)
    (config['projects'] || []).any? { |p| project_has_exposed_ports?(p) }
  end

  # Returns true when this specific project has app.run entries with exposed ports.
  def self.project_has_exposed_ports?(project_config)
    entries = project_config.dig('app', 'run')
    entries.is_a?(Array) && entries.any? { |e| e.is_a?(Hash) && e['port'] }
  end

  # Returns true when Azure SSO credentials are missing or still set to the
  # `stub-client-id` fallback baked into `config/initializers/devise.rb`.
  # In that state the OAuth request reaches Microsoft but fails with
  # AADSTS700016 ("Application with identifier 'stub-client-id' was not
  # found"). Mirrors devise.rb's resolution order: ENV → config['azure']
  # → stub fallback.
  def self.azure_stub_credentials?(config = nil)
    client_id = ENV.fetch('AZURE_AD_CLIENT_ID', nil)
    client_id ||= config&.dig('azure', 'client_id')
    client_id.nil? || client_id.to_s.strip.empty? || client_id == 'stub-client-id'
  end

  # Validate global config. Called at startup before validate_projects!.
  # Raises ConfigError on invalid values.
  def self.validate!(config)
    ConfigValidator.validate_globals!(config)
    validate_projects!(config)
  end

  # Validate per-project config for all projects. Called by validate!.
  # Raises ConfigError if config is incomplete or invalid.
  def self.validate_projects!(config)
    (config['projects'] || []).each_with_index do |project_config, idx|
      path = project_config['path']
      unless path.is_a?(String) && !path.strip.empty?
        raise ConfigError, "projects[#{idx}]: 'path' is required and must be a non-empty string."
      end

      ConfigValidator.validate_project!(project_config, path)
    end
  end

  # -- load helpers --

  def self.parse_yaml(config_path)
    return {} unless File.exist?(config_path)

    YAML.safe_load_file(config_path, permitted_classes: [Symbol]) || {}
  end
  private_class_method :parse_yaml

  # Shallow-merge the YAML over the defaults, skipping the keys we no longer
  # read (IGNORED_GLOBAL_FIELDS) and dropping the retired `web.enabled` subkey.
  def self.merge_yaml!(config, yaml)
    yaml.each do |k, v|
      next if v.nil? || IGNORED_GLOBAL_FIELDS.include?(k)

      config[k] = v
    end
    config['web'] = config['web'].except('enabled') if config['web'].is_a?(Hash)
  end
  private_class_method :merge_yaml!

  def self.merge_env!(config)
    ENV_MAPPING.each do |env_key, config_key|
      config[config_key] = ENV[env_key] if ENV.key?(env_key)
    end
  end
  private_class_method :merge_env!

  # Coerce every declared numeric global that reads as a number — a YAML
  # `poll_interval: '120'` still lands as the Integer 120.
  #
  # What changed with Autodev #58 is what happens to a value that is *not* a
  # number: it is left exactly as the operator wrote it instead of being run
  # through `.to_i`. `'quatorze'.to_i` is 0, and 0 is a meaningful value for
  # `pipeline_watch_max_days` (it disables the age bound) and for `clone_depth`,
  # so coercing first destroyed the evidence and turned a typo into a silently
  # switched-off safety net. Keeping the raw value is what lets
  # `ConfigValidator` refuse it and name it.
  def self.coerce_numeric_settings!(config)
    NumericSettings.fields.each do |field|
      next unless config.key?(field)

      coerced = NumericSettings.integer(config[field])
      config[field] = coerced unless coerced.nil?
    end
  end
  private_class_method :coerce_numeric_settings!

  # Warn when a now-ignored key is still present in the YAML, so operators
  # know to remove it. The value has no effect (DEFAULTS / per-project config
  # are used instead).
  def self.warn_ignored!(yaml)
    IGNORED_GLOBAL_FIELDS.each do |field|
      warn "[DEPRECATION] '#{field}' is no longer read from config.yml and is ignored." if yaml.key?(field)
    end
    warn_db_backed_project_fields!(yaml)
    return unless yaml['web'].is_a?(Hash) && yaml['web'].key?('enabled')

    warn "[DEPRECATION] 'web.enabled' is no longer read from config.yml (the web UI is always on)."
  end
  private_class_method :warn_ignored!

  # Warn once per per-project key that has moved to the DB and is now read from
  # there at runtime. Fires at config load (not in the importer, which is the
  # one place the YAML value is meant to be consumed): the point is to catch an
  # operator who edits config.yml expecting it to take effect when the DB row is
  # already authoritative.
  def self.warn_db_backed_project_fields!(yaml)
    present = Array(yaml['projects']).flat_map { |p| p.is_a?(Hash) ? p.keys : [] }.uniq
    (DB_BACKED_PROJECT_FIELDS & present).each do |field|
      warn "[DEPRECATION] per-project '#{field}' in config.yml is now stored in the database and read " \
           'from there at runtime; the YAML value only seeds the DB via ' \
           'autodev:migrate_projects_from_yaml and will stop being read in a future version.'
    end
  end
  private_class_method :warn_db_backed_project_fields!
end
