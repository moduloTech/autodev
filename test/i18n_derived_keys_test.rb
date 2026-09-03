# frozen_string_literal: true

require_relative 'rails_helper'

# Autodev #68 — a key missing from *both* locales must fail a test.
#
# `test/locales_test.rb` checks that the two YAML tables agree with each other:
# every FR key has an EN counterpart and vice versa. That compares the files to
# each other and never to the code, so a key present in neither language
# satisfies parity — and `Locales.t` answers a missing key with the key's own
# name, which is then written verbatim onto a GitLab thread or into the
# dashboard. Silent when written, visible only to a human reading the output.
#
# It has shipped twice, both times found by accident while working on something
# else, both fixed in passing by Autodev #66:
#
#   * `activity_mr_closed` existed in neither table, so every merged MR wrote the
#     literal string `activity_mr_closed` on its ticket's GitLab activity note.
#     Two production tickets carry the line.
#   * `web_event_abandon` was missing from Autodev #60 onwards, so every abandon
#     transition rendered the bare symbol `abandon` in the /issues/:id timeline.
#
# The two share a shape: the key is **derived from a symbol at the call site** —
# the AASM event name, the symbol handed to `log_activity`, the give-up reason.
# Nobody writes the key, so nobody notices it is missing, and a test that
# compares two files to each other structurally cannot see it. What can is a test
# that derives the expected set from the code, the way
# `test/rails_lib_loading_test.rb` derives the lib constant set from
# `lib/autodev.rb`'s require graph (Autodev #64) and
# `test/api_failure_is_not_a_verdict_test.rb` derives its verdict from a scan of
# the delivery path (Autodev #62).
#
# Nothing below lists keys. Each family's population is either a runtime
# enumeration (`Issue.aasm.events`, `ActivityEvent::KINDS`,
# `HealthReport::CHECKS`, `LabelHandover::EXPECTED_ACTION`, …) or a scan of the
# call sites, for the vocabularies that exist nowhere but in call arguments. Two
# guards keep it that way, and they are the part that does not go stale:
#
#   * a call site whose key argument is not a literal must be declared in
#     `DYNAMIC_KEY_SITES` with the family that covers the values it takes, and a
#     declaration that no longer matches a call site is reported as stale
#     (Autodev #73 — an exception nobody can see is dead reads like a live one);
#   * an interpolated key namespace (`:"web_foo_#{x}"`) must be declared in
#     `COVERED_NAMESPACES` with the family that covers it — for *any* stem since
#     Autodev #73, not just the five prefixes somebody had thought of, because the
#     keys this product interpolates most (the notification keys) carry no prefix
#     at all;
#   * a key handed straight to `Locales.t`, with no wrapper to prefix it and no
#     family to enumerate it, is read off the call site like the rest (Autodev #73).
#     Four such keys were live and checked by nothing.
#
# So a symbol added to an existing family is covered without touching this file,
# and a new *shape* of derived key fails it until it is declared. What a
# declaration is worth once written is a separate question, and the answer is
# stated at `DYNAMIC_KEY_SITES` rather than left to be assumed.

# --- the two tables, read once ---------------------------------------------

# Reads the YAML directly, like the FR/EN parity test: no dependence on I18n's
# runtime load path or on the Rails railtie having run.
module LocaleKeyTables
  LANGUAGES = %i[fr en].freeze

  def self.table(language)
    @table ||= {}
    @table[language] ||= Locales.merged_for(language).keys.to_set(&:to_s)
  end

  # The languages `key` is absent from — `[]` when both have it. Naming the
  # language is half the point of the ticket: "something is missing" moves the
  # problem, "activity_mr_closed (en)" ends it.
  def self.absent_from(key)
    LANGUAGES.reject { |language| table(language).include?(key.to_s) }
  end
end

# One `assert` for a whole family, reporting every gap as
# "<key> (<language>) — <where the expectation comes from>".
module LocaleKeyAssertions
  # `expected` maps a key to the origin that demands it.
  def assert_localized(expected, rule)
    gaps = expected.flat_map do |key, origin|
      LocaleKeyTables.absent_from(key).map { |language| "  #{key} (#{language}) — required by #{origin}" }
    end

    assert_empty gaps, "#{rule}\n#{gaps.join("\n")}\n"
  end

  # Every key a family demands, mapped to its origin.
  def keys_for(values, format, origin, except: {})
    values.reject { |value| except.key?(value.to_s) }
          .to_h { |value| [format % value, "#{origin} `#{value}`"] }
  end
end

# --- the sources -----------------------------------------------------------

# Every Ruby file autodev ships, comment-only lines dropped.
#
# `test/` is deliberately out: `log_activity(issue, :whatever)` inside a stub is
# not a call the product makes, and requiring a locale entry for it would let the
# fixtures dictate the vocabulary. That is the one exclusion by construction; the
# named ones are declared where they are used.
module I18nSources
  ROOT = File.expand_path('..', __dir__)
  GLOBS = ['lib/**/*.rb', 'app/**/*.rb', 'bin/autodev'].freeze

  def self.each(&)
    files.each(&)
  end

  def self.files
    @files ||= GLOBS.flat_map { |glob| Dir[File.join(ROOT, glob)] }.sort.map do |path|
      [path.delete_prefix("#{ROOT}/"), code_only(File.read(path))]
    end
  end

  # A whole-line comment carries no call. Trailing comments are left alone: they
  # cannot start a call, and stripping from `#` onwards would maul any string
  # literal or interpolation containing one.
  def self.code_only(text)
    text.lines.map { |line| line.match?(/\A\s*#/) ? "\n" : line }.join
  end
end

# --- the call-site scan ----------------------------------------------------

# Three of the four vocabularies this file checks exist nowhere as data: they are
# the symbols the code passes to `log_activity`, to `notify_localized` and to
# `abandon_issue`. So they are read off the call sites, textually and knowingly —
# the same trade Autodev #62's source guard makes, for the same reason: what is
# being checked is a property of the source a reader sees.
module KeySites # rubocop:disable Metrics/ModuleLength
  # Module methods with a private half; nothing here is mixed into a test case.
  extend self

  # A call whose argument number `index` (0-based) is a locale key, and the
  # vocabulary that key belongs to.
  Call = Struct.new(:name, :index, :vocabulary)

  CALLS = [
    Call.new('log_activity', 1, :activity),
    Call.new('log_activity_warn', 0, :activity),
    Call.new('ActivityLogger.post', 2, :activity),
    Call.new('ActivityLogger.warn_event', 1, :activity),
    # A wrapper around `ActivityLogger.post`, scanned at its own call sites
    # because the post inside it only ever sees a variable.
    Call.new('close_row!', 1, :activity),
    Call.new('notify_localized', 1, :notification),
    Call.new('notify_stop', 1, :notification),
    # `abandon_issue`'s reason is simultaneously the `attention_reason` column
    # value, the notification key and the activity key (IssueAbandonment).
    Call.new('abandon_issue', 1, :attention_reason),
    # …and `handle_stagnation` derives `stagnation_<type>` from this argument.
    Call.new('bail_on_stagnation?', 1, :stagnation_type),
    # The raw door (Autodev #73). Everything above is a wrapper that prefixes or
    # routes; `Locales.t` is the function they all end at, and it is also called
    # directly — with keys that carry **no prefix at all**, which is the normal
    # shape of a notification key in this product (`done_nominal`,
    # `spec_unclear_header`). Those keys were checked by nothing: not by a family
    # (no symbol reaches `notify_localized` for them) and not by the literal scan
    # below (which only knows five namespaces). Verified by injection:
    # `Locales.t(:absent_from_both_tables, locale: :fr)` in `lib/` left the whole
    # file green.
    Call.new('Locales.t', 0, :bare_key)
  ].freeze

  # "<file> <call>" => why the key argument is not a literal there, and where the
  # values it takes are covered. This is the guard: a new call site with a
  # literal needs nothing, a new one with a variable fails until it is declared.
  #
  # ## What a declaration proves, and what it does not (Autodev #73)
  #
  # Two things are checked mechanically: that a call site handing a variable to a
  # localised message is named here, and — since #73 — that an entry still matches a
  # call site that exists (`test_no_declaration_outlives_the_call_site_it_excuses`).
  #
  # The value is an **English sentence, and nothing verifies it**. "the :activity
  # vocabulary", "scanned at its call sites" — a reader has to take those on trust,
  # and if the family it names stops covering the values the call takes, or never
  # covered them, this file stays green. The same limit sits on
  # `COVERED_NAMESPACES`, on `NOT_LOCALE_NAMESPACES` and on `NOT_LOCALE_KEYS`: each
  # is a sentence asserting something about code that is not read back.
  #
  # This is not hypothetical for the sibling guard: two entries of
  # `test/api_failure_is_not_a_verdict_test.rb`'s `ALLOWED_SWALLOWS` claimed "no read
  # inside" while an unprotected GitLab read sat underneath, and it stayed green
  # through a review. Read a green run here as "every derived-key shape is
  # declared", never as "every declaration is true", and re-read the sentence
  # against the code whenever you touch what it describes.
  DYNAMIC_KEY_SITES = {
    # The definitions themselves — `def log_activity(issue, key, …)` reached
    # through the module's own delegation, not a call site with a vocabulary.
    'lib/autodev/activity_logger.rb ActivityLogger.post' => 'the delegation inside `log_activity`',
    'lib/autodev/activity_logger.rb ActivityLogger.warn_event' => 'the delegation inside `log_activity_warn`',
    'lib/autodev/poll_router.rb ActivityLogger.post' => "PollRouter's own `log_activity` wrapper, " \
                                                        'scanned at its call sites',
    'app/services/autodev/external_state.rb ActivityLogger.post' => 'the delegation inside `close_row!`, ' \
                                                                    'scanned at its call sites',
    # The abandon point: `reason` is whatever `abandon_issue` was called with,
    # which is the :attention_reason vocabulary above.
    'lib/autodev/issue_abandonment.rb log_activity' => 'the abandon reason (`activity_<reason>`)',
    'lib/autodev/issue_abandonment.rb notify_localized' => 'the abandon reason (the bare notification key)',
    # `:"stagnation_#{type}"`, from the `bail_on_stagnation?` sites above.
    'lib/autodev/pipeline_monitor/stagnation_detector.rb abandon_issue' => 'the stagnation type ' \
                                                                           '(`stagnation_<type>`)',
    # A human moved the workflow label: the reason comes from
    # `LabelHandover::EXPECTED_ACTION`, checked as its own family.
    'app/services/autodev/external_state.rb close_row!' => 'the handover reason (`activity_handover_<reason>`)',
    'app/services/autodev/external_state.rb notify_stop' => 'the handover reason (`handover_<reason>`)',
    # The `Locales.t` sites that take their key from a variable (Autodev #73). Each
    # is a wrapper whose own call sites are scanned above, or a lookup in a table
    # of literals the literal scan reads.
    'lib/autodev/activity_logger.rb Locales.t' => 'the :activity vocabulary (activity_<key>)',
    'lib/autodev/issue_notifier.rb Locales.t' => 'the notification key and its `suffix:`',
    'app/services/autodev/external_state.rb Locales.t' => "`notify_stop`'s key",
    'app/helpers/web/i18n_helpers.rb Locales.t' => "`t_web`'s delegation — the `web_` literals",
    'lib/autodev/numeric_settings.rb Locales.t' => '`MESSAGE_KEYS`, two literal `cli_` symbols',
    'app/services/autodev/ticket_reclaim.rb Locales.t' => "`reclaim!`'s `message_key:` argument",
    # `OUTAGE_REASONS[outcome]`, enumerated as its own family by
    # `attention_reasons` below (alpha-53 review, G3).
    'lib/autodev/review_outage_bound.rb abandon_issue' => 'the review-outage reason ' \
                                                          '(`ReviewOutageBound::OUTAGE_REASONS`)'
  }.freeze

  LITERAL_SYMBOL = /\A:([a-z_]\w*)\z/
  # `… ? :pipeline_green_done : :done`: a two-branch choice of literals is still two literals.
  TERNARY_SYMBOLS = /\A.+\?\s*:([a-z_]\w*)\s*:\s*:([a-z_]\w*)\z/
  # `notify_localized(…, suffix: :abandon_reassigned)` — a second, var-free
  # template appended after the message (Autodev #60). Also a key.
  SUFFIX_SYMBOL = /\bsuffix:\s*\(?\s*:([a-z_]\w*)/
  # Every value written to `issues.attention_reason`.
  COLUMN_WRITE = /attention_reason:\s*([^,)\n]+)/
  DEPTH = { '(' => 1, '[' => 1, '{' => 1, ')' => -1, ']' => -1, '}' => -1 }.freeze

  # `lib/autodev/issue_abandonment.rb` writes `attention_reason: reason.to_s`;
  # `reason` is the `abandon_issue` argument, covered at its call sites. Every
  # other non-literal write is `nil`, which is a clearing write and no key.
  DYNAMIC_COLUMN_WRITES = ['lib/autodev/issue_abandonment.rb'].freeze

  # { vocabulary => { symbol => origin } }
  def vocabularies = scan[:found]

  # Call sites whose key argument is neither a literal nor declared.
  def undeclared_sites = scan[:undeclared].uniq

  # Every call site whose key argument is not a literal, declared or not. A
  # declaration naming a site that is not in here is stale, and a stale
  # declaration is an exception nobody can see is dead (Autodev #73).
  def dynamic_sites = scan[:dynamic].uniq

  def scan
    @scan ||= { found: Hash.new { |hash, key| hash[key] = {} }, undeclared: [], dynamic: [] }.tap do |sinks|
      I18nSources.each do |rel, code|
        CALLS.each { |call| collect_call(rel, code, call, sinks) }
        collect_regexp(rel, code, SUFFIX_SYMBOL, sinks[:found][:notification], 'a `suffix:` argument in')
        collect_column_writes(rel, code, sinks[:found][:attention_reason], sinks[:undeclared])
      end
    end
  end

  private

  def collect_call(rel, code, call, sinks)
    code.to_enum(:scan, call_pattern(call)).each do
      expression = argument_at(code, Regexp.last_match.end(0), call.index)
      record_key(rel, call, literal_symbols(expression), sinks)
    end
  end

  def record_key(rel, call, symbols, sinks)
    site = "#{rel} #{call.name}"
    sinks[:dynamic] << site if symbols.empty?
    sinks[:undeclared] << site if symbols.empty? && !DYNAMIC_KEY_SITES.key?(site)
    symbols.each { |symbol| sinks[:found][call.vocabulary][symbol] = "`#{call.name}` in #{rel}" }
  end

  def collect_regexp(rel, code, pattern, sink, origin)
    code.scan(pattern) { sink[Regexp.last_match(1)] = "#{origin} #{rel}" }
  end

  # The column is written with a literal at the three sites that do not go
  # through `abandon_issue` (the review-failure give-up, the infra-recheck
  # re-arm, the dormant audit).
  def collect_column_writes(rel, code, sink, undeclared)
    code.scan(COLUMN_WRITE) do
      raw = Regexp.last_match(1).strip
      next if raw == 'nil'

      value = column_literal(raw)
      undeclared << "#{rel} attention_reason:" if value.nil? && !DYNAMIC_COLUMN_WRITES.include?(rel)
      sink[value] = "the `attention_reason:` write in #{rel}" if value
    end
  end

  def column_literal(raw)
    value = raw.delete_prefix(':').gsub(/\A['"]|['"]\z/, '')
    value.match?(/\A[a-z_][a-z0-9_]*\z/) ? value : nil
  end

  # Not preceded by a word character, a dot or `def`, so `def close_row!(…)` and
  # `Foo#log_activity` are not read as call sites; `::ActivityLogger.post` is.
  def call_pattern(call)
    /(?<![\w.])(?<!def )(?:::)?#{Regexp.escape(call.name)}\(/
  end

  def literal_symbols(expression)
    return [] if expression.nil?
    return [Regexp.last_match(1)] if expression.match(LITERAL_SYMBOL)
    return Regexp.last_match.captures if expression.match(TERNARY_SYMBOLS)

    []
  end

  # The argument at `index` of the call whose opening paren ends at `from`,
  # counting nesting so `ActivityLogger.post(Ctx.new(a, b, c), issue, :key)` has
  # three arguments and not five. Nil when the call has fewer.
  def argument_at(code, from, index)
    depth = 1
    args = ['']
    code[from..].each_char do |char|
      depth += DEPTH.fetch(char, 0)
      return args[index]&.strip if depth.zero?

      depth == 1 && char == ',' ? args << '' : args[-1] += char
    end
    nil
  end
end

# --- 1. the families whose population is a runtime enumeration -------------

class DerivedI18nKeysTest < Minitest::Test
  include LocaleKeyAssertions

  # The defect the ticket names second: `web_event_abandon` was absent from
  # Autodev #60 to #66, so `Web::I18nHelpers#event_label` fell through to its
  # `event.to_s` fallback and the /issues/:id timeline printed `abandon`.
  #
  # `Issue.aasm.events` is the machine itself, so an event added to the model is
  # covered here the moment it is added.
  def test_every_aasm_event_of_issue_has_a_timeline_label
    events = Issue.aasm.events.map(&:name)

    assert_localized keys_for(events, 'web_event_%s', 'the AASM event'),
                     'Every AASM event of Issue needs a `web_event_<event>` label — ' \
                     "`Web::I18nHelpers#event_label` renders the bare symbol without it.\n" \
                     "Missing (#{events.size} events checked):"
  end

  # The `kind` column of the rows the issue timeline and /stream render.
  # `ActivityEvent.user_visible` is the single definition of "a row somebody
  # asked to see", so it is also the definition of which kinds need a label; the
  # machinery kinds are never rendered and deliberately have none.
  def test_every_kind_rendered_in_the_timeline_has_a_label
    kinds = ActivityEvent::KINDS - ActivityEvent::MACHINERY_KINDS

    assert_localized keys_for(kinds, 'web_event_kind_%s', 'the user-visible ActivityEvent kind'),
                     'Every kind `ActivityEvent.user_visible` can return needs a ' \
                     "`web_event_kind_<kind>` label — the timeline's Type column shows the raw " \
                     "value without it.\nMissing:"
  end

  # `/admin/health`'s cards are titled `web_admin_health_check_<name>` from
  # `@report[:checks]`' own keys, which are `CHECKS`. This one goes through
  # `t_web`, not `Locales.lookup`, so a missing key prints the key itself.
  def test_every_health_check_has_a_card_title
    assert_localized keys_for(Autodev::HealthReport::CHECKS, 'web_admin_health_check_%s', 'the health check'),
                     'Every HealthReport check needs a `web_admin_health_check_<name>` title for ' \
                     "its /admin/health card.\nMissing:"
  end

  # A human moved the workflow label. `EXPECTED_ACTION`'s keys are the three
  # verdicts `LabelHandover#verdict` can return, and the reason is used twice:
  # `handover_<reason>` for the GitLab notice, `activity_handover_<reason>` for
  # the activity line (`ExternalState#stop_on_handover`).
  def test_every_handover_reason_has_a_notice_and_an_activity_line
    reasons = Autodev::LabelHandover::EXPECTED_ACTION.keys

    assert_localized keys_for(reasons, 'handover_%s', 'the handover verdict')
      .merge(keys_for(reasons, 'activity_handover_%s', 'the handover verdict')),
                     'Every LabelHandover verdict needs both a `handover_<reason>` GitLab notice ' \
                     "and an `activity_handover_<reason>` line.\nMissing:"
  end

  # `Web::Helpers#locale_label` renders the per-issue locale column.
  def test_every_available_locale_has_a_label
    assert_localized keys_for(Web::I18nHelpers::AVAILABLE_LOCALES, 'web_locale_%s', 'the available locale'),
                     "Every available locale needs a `web_locale_<code>` label.\nMissing:"
  end

  # The per-project config form hints every field with
  # `web_project_edit_desc_<field>`; the fields are the project's own config
  # columns, so a setting added to `Project` (Autodev #58 added four) needs one.
  def test_every_project_config_field_has_a_form_hint
    fields = Project::SCALAR_CONFIG_KEYS + Project::LIST_CONFIG_KEYS

    assert_localized keys_for(fields, 'web_project_edit_desc_%s', 'the project config field'),
                     'Every editable project config field needs a `web_project_edit_desc_<field>` ' \
                     "hint under its input.\nMissing:"
  end
end

# --- 2. the families whose population only exists at the call sites --------

class ScannedI18nKeysTest < Minitest::Test
  include LocaleKeyAssertions

  # The defect the ticket names first: `activity_mr_closed` existed in neither
  # table, so a merged MR wrote `activity_mr_closed` on the GitLab thread.
  #
  # `ActivityLogger.build_entry` prefixes every key with `activity_`, so the
  # expected set is "every symbol that reaches it", from all five entry points
  # (`log_activity`, `log_activity_warn`, the two class methods, `close_row!`).
  def test_every_activity_symbol_has_a_template
    symbols = KeySites.vocabularies[:activity]

    assert_operator symbols.size, :>, 30, "the activity scan found only #{symbols.size} symbols"
    assert_localized symbols.to_h { |symbol, origin| ["activity_#{symbol}", origin] },
                     'Every symbol handed to the activity log needs an `activity_<symbol>` ' \
                     "template — `Locales.t` writes the key's own name on the GitLab note " \
                     "without it.\nMissing:"
  end

  # `notify_localized` / `notify_stop` post a one-off GitLab comment. Their keys
  # carry no prefix, so the symbol *is* the key.
  def test_every_notification_symbol_has_a_template
    symbols = KeySites.vocabularies[:notification]

    assert_operator symbols.size, :>, 9, "the notification scan found only #{symbols.size} symbols"
    assert_localized symbols,
                     "Every symbol handed to a GitLab notification needs a template.\nMissing:"
  end

  # An abandon reason feeds three sinks, and it is the same word in all three by
  # construction (`IssueAbandonment`): the GitLab comment (bare key), the
  # activity line (`activity_<reason>`) and — via `attention_reason` on the row —
  # the plain-language explanation on the watch card, interpolated in
  # `Web::Views::Concerns::WatchCards#explain_key`.
  #
  # `dormant_exhausted` has no notification key **by design**: the dormant audit
  # flags the row and posts nothing on GitLab (`ActivityLogger.warn_event` only,
  # DB side). Declared here rather than filtered out silently.
  NO_GITLAB_COMMENT = {
    'dormant_exhausted' => 'the dormant audit posts no GitLab comment — it only flags the row'
  }.freeze

  def test_every_attention_reason_has_its_three_sinks
    reasons = attention_reasons

    assert_operator reasons.size, :>, 5, "the attention-reason scan found only #{reasons.size} reasons"
    assert_localized expected_attention_keys(reasons),
                     'Every attention reason needs its GitLab comment (bare key), its activity ' \
                     'line (`activity_<reason>`) and its watch-card explanation ' \
                     "(`web_errors_explain_attention_<reason>`).\nMissing:"
  end

  # The raw door (Autodev #73): a key handed straight to `Locales.t`, with no
  # wrapper to prefix it and no family to enumerate it. Four such keys were live
  # and unchecked — `question_answered_{header,footer}`,
  # `spec_unclear_{header,footer}` — and a notification key carries no prefix, so
  # the literal scan below could not see them either.
  def test_every_key_handed_straight_to_locales_t_exists
    symbols = KeySites.vocabularies[:bare_key]

    assert_operator symbols.size, :>, 5, "the Locales.t scan found only #{symbols.size} keys"
    assert_localized symbols,
                     "Every key passed straight to `Locales.t` needs a template.\nMissing:"
  end

  # A declaration that no longer matches a call site is an exception nobody can
  # see is dead: the wrapper was renamed, or its key became a literal, and the
  # entry stays behind whitelisting a site that no longer exists — while reading
  # like a live statement about the code. This is as far as the mechanical check
  # on a declaration goes; see the note at the top of `DYNAMIC_KEY_SITES` for what
  # it still cannot check.
  def test_no_declaration_outlives_the_call_site_it_excuses
    stale = KeySites::DYNAMIC_KEY_SITES.keys - KeySites.dynamic_sites

    assert_empty stale, <<~MSG
      These KeySites::DYNAMIC_KEY_SITES entries match no call site any more: #{stale.join(', ')}.

      Either the call moved, or it takes a literal key now and needs no excuse.
      Delete the entry: an exception that excuses nothing reads like one that
      excuses something.
    MSG
  end

  # The guard that keeps the four families above derived rather than listed: a
  # call site handing a *variable* to one of them contributes nothing to the
  # scan, so its keys would go unchecked. Autodev #62's `ALLOWED_SWALLOWS` makes
  # the same trade — the exceptions live in one declared list, with a sentence.
  def test_every_dynamic_key_call_site_is_declared
    assert_empty KeySites.undeclared_sites, <<~MSG
      A localized-message call here takes its key from a variable: #{KeySites.undeclared_sites.join(', ')}.

      The scan cannot read that key, so nothing checks the locale tables for it —
      which is Autodev #68. Either pass a literal symbol, or add the site to
      KeySites::DYNAMIC_KEY_SITES naming the family that enumerates the values it
      takes (and add that family if it does not exist yet).
    MSG
  end

  private

  # Where a give-up reason comes from: the `abandon_issue` call sites, the
  # `stagnation_<type>` its shared bail-out derives, and the three literal writes
  # to the column that do not go through the abandon point.
  def attention_reasons
    KeySites.vocabularies[:attention_reason].merge(
      KeySites.vocabularies[:stagnation_type]
              .transform_keys { |type| "stagnation_#{type}" }
    ).merge(review_outage_reasons)
  end

  # `ReviewOutageBound` reaches `abandon_issue` with a reason looked up in a
  # table rather than written at the call site, so the scan cannot see it and
  # the constant is the vocabulary (alpha-53 review, G3).
  def review_outage_reasons
    ReviewOutageBound::OUTAGE_REASONS.values.to_h do |reason|
      [reason.to_s, 'ReviewOutageBound::OUTAGE_REASONS']
    end
  end

  def expected_attention_keys(reasons)
    keys_for(reasons.keys, '%s', 'the attention reason', except: NO_GITLAB_COMMENT)
      .merge(keys_for(reasons.keys, 'activity_%s', 'the attention reason'))
      .merge(keys_for(reasons.keys, 'web_errors_explain_attention_%s', 'the attention reason'))
  end
end

# --- 3. the literal half, and the shape itself -----------------------------

# The families above cover the keys nobody writes. This covers the ones somebody
# does: a key spelled out in the source has to exist too, and a typo in one is
# just as invisible to the parity test as an absence. Cheap, because our key
# namespaces are unambiguous enough to be read straight off the source.
class LiteralI18nKeysTest < Minitest::Test
  include LocaleKeyAssertions

  # A symbol literal in one of the locale namespaces, not preceded by `:` (so
  # `Foo::bar` is not read as a symbol).
  NAMESPACED_SYMBOL = /(?<![\w:]):((?:web|activity|cli|notify|handover)_[a-z0-9_]+)\b/

  # Symbols that fall in a locale namespace by coincidence and are not keys.
  # Explicit and motivated, per the ticket: a silent filter here would be the
  # hole the whole file exists to close.
  NOT_LOCALE_KEYS = {
    'web_url' => "GitLab's own field name on a job/MR payload (`GitlabHelpers.field(job, :web_url)`)"
  }.freeze

  def test_every_literal_key_written_in_the_sources_exists
    found = literal_keys

    assert_operator found.size, :>, 300, "the literal scan found only #{found.size} keys"
    assert_localized found,
                     'A locale key is spelled out in the source but missing from the tables — ' \
                     "`Locales.t` will render the key itself.\nMissing:"
  end

  # The second guard: an interpolated key namespace has to be covered by a
  # family. This is the view-side counterpart of
  # `ScannedI18nKeysTest#test_every_dynamic_key_call_site_is_declared` — three of
  # these render through `t_web`, where a missing key prints verbatim.
  COVERED_NAMESPACES = {
    'activity_' => 'ActivityLogger prefixes every activity key — the :activity vocabulary',
    'web_event_' => 'the AASM events of Issue',
    'web_event_kind_' => 'the user-visible ActivityEvent kinds',
    'web_errors_explain_attention_' => 'the attention reasons',
    'web_admin_health_check_' => 'the HealthReport checks',
    'web_locale_' => 'the available locales',
    'handover_' => 'the LabelHandover verdicts',
    'web_project_edit_desc_' => 'the editable project config fields',
    # The only one with no runtime population: the four bullets of the config
    # form's help panel are a literal `%i[…]` in the view that renders them, so a
    # family here would copy that list rather than derive anything. Their FR/EN
    # pair is what the parity test covers, and a bullet added without a key is
    # visible in the panel on the next page load.
    'web_project_edit_help_' => 'a literal list inside the view that renders it — no derivation to make',
    # No prefix at all, and that is the point of widening the scan below (Autodev
    # #73): an attention reason is its own notification key, so `:"stagnation_…"`
    # is a locale key whose namespace is none of the five the old regex knew.
    'stagnation_' => 'the stagnation types, via the `bail_on_stagnation?` sites — the attention reasons'
  }.freeze

  # Symbols built by interpolation that fall outside every locale namespace
  # because they are not keys. Declared rather than filtered silently, for the
  # same reason as `NOT_LOCALE_KEYS`: the widened scan below reads *any* prefix,
  # which is what lets it see `stagnation_`, and the price is naming the handful
  # of interpolated symbols this codebase builds for other purposes.
  NOT_LOCALE_NAMESPACES = {
    'has_' => "StackDetector's per-gem flags (`:\"has_\#{gem}\"`), a stack fingerprint",
    'pending_' => "HealthReport's per-migration meta keys on the `migrations` card",
    'claude_usage_' => 'PipelineMonitor#claude_unavailable_reason (Autodev #108): the ' \
                       '`poll_inconclusive!` flag and its log line name the recorded UsageChecker ' \
                       'verdict for an operator reading the log, never rendered through Locales.t/t_web'
  }.freeze

  # Widened from `(?:web|activity|cli|notify|handover)` to any stem (Autodev #73).
  # The five namespaces were the ones somebody had thought of, and the keys this
  # product interpolates most — the notification keys — carry no prefix at all, so
  # `:"stagnation_\#{type}"` was invisible. Verified by injection:
  # `Locales.t(:"done_\#{issue.status}", locale: :fr)` in `lib/` left the file green.
  #
  # A symbol built *entirely* by interpolation (`:"\#{name}_skill"`) is out of
  # reach by construction: there is no stem to attribute it to, and a `''`
  # namespace in the table above would whitelist every future one. No locale key
  # in this codebase is built that way — they all carry a stable stem, which is
  # what makes them greppable at all — and that is the limit rather than a claim.
  INTERPOLATED_KEY = /:"([a-z0-9_]+)\#\{/

  def test_every_interpolated_key_namespace_is_covered_by_a_family
    undeclared = undeclared_namespaces

    assert_empty undeclared, <<~MSG
      A locale key is built by interpolation here: #{undeclared.join(', ')}.

      Its keys exist nowhere as text, so only a family deriving them from the same
      values the code interpolates can check them. Add one, and declare the
      namespace in LiteralI18nKeysTest::COVERED_NAMESPACES pointing at it.
    MSG
  end

  private

  def undeclared_namespaces
    known = COVERED_NAMESPACES.keys + NOT_LOCALE_NAMESPACES.keys
    I18nSources.files.flat_map do |rel, code|
      code.scan(INTERPOLATED_KEY).flatten.uniq
          .reject { |namespace| known.include?(namespace) }
          .map { |namespace| "#{rel}: :\"#{namespace}\#{…}\"" }
    end
  end

  def literal_keys
    I18nSources.files.each_with_object({}) do |(rel, code), acc|
      code.scan(NAMESPACED_SYMBOL).flatten.each do |key|
        acc[key] ||= "the literal `:#{key}` in #{rel}" unless NOT_LOCALE_KEYS.key?(key)
      end
    end
  end
end
