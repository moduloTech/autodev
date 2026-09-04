# frozen_string_literal: true

require_relative 'test_helper'

class LocalesTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- one file, every locale guard
  def test_french_template_with_interpolation
    msg = Locales.t(:processing_started, locale: :fr, tag: '**autodev**')

    assert_includes msg, '**autodev**'
    assert_includes msg, 'traitement en cours'
  end

  def test_english_template_with_interpolation
    msg = Locales.t(:processing_started, locale: :en, tag: '**autodev**')

    assert_includes msg, '**autodev**'
    assert_includes msg, 'processing in progress'
  end

  def test_mr_created_includes_url
    msg = Locales.t(:mr_created, locale: :en, tag: 'tag', mr_url: 'https://example.com/mr/1')

    assert_includes msg, 'https://example.com/mr/1'
  end

  def test_unknown_locale_falls_back_to_french
    msg = Locales.t(:processing_started, locale: :de, tag: 'tag')

    assert_includes msg, 'traitement en cours'
  end

  def test_unknown_key_returns_key_string
    msg = Locales.t(:nonexistent_key, locale: :fr)

    assert_equal 'nonexistent_key', msg
  end

  # Parity is half of the project rule: the two tables must agree with each
  # other. The other half — that the keys the *code* asks for exist at all — is
  # `test/i18n_derived_keys_test.rb` (Autodev #68). A key present in neither
  # language passes both tests below, and `Locales.t` then renders its own name.
  def test_all_fr_keys_have_en_counterparts
    fr_keys = Locales.merged_for(:fr).keys
    en_keys = Locales.merged_for(:en).keys
    missing = fr_keys - en_keys

    assert_empty missing, "EN locale is missing keys: #{missing.join(', ')}"
  end

  def test_all_en_keys_have_fr_counterparts
    fr_keys = Locales.merged_for(:fr).keys
    en_keys = Locales.merged_for(:en).keys
    missing = en_keys - fr_keys

    assert_empty missing, "FR locale is missing keys: #{missing.join(', ')}"
  end

  # Key parity says nothing about whether the two sides of a key take the same
  # arguments — `Locales.t(key, **vars)` interpolates whatever `%{…}` the
  # loaded template names and silently ignores the rest, so a key present in
  # both tables with different placeholders renders fine in whichever locale
  # is loaded and raises (`I18n::MissingInterpolationArgument`) only in the
  # other, the day somebody's `issue.locale` picks it. The neutral review of
  # the alpha-54 lot checked the four `cli_boot_guard_orphan_*` keys' by hand
  # and found them matched; this is that check turned into a suite guard over
  # every key both tables carry, so a future key does not depend on somebody
  # doing the same check by hand again.
  #
  # Values that are not a String (`devise`'s nested scope, the pluralized
  # `web_autospec_attachments_label` hash) are out of scope: `merged_for`
  # returns them verbatim rather than flattened, and a `%{…}` scan over a Hash
  # answers nothing useful.
  def placeholder_names(template)
    template.to_s.scan(/%\{(\w+)\}/).flatten.map(&:to_sym).sort.uniq
  end

  # nil unless both sides are strings with a placeholder mismatch — the
  # extraction that keeps the test method itself a plain `filter_map`.
  def placeholder_mismatch(key, fr_value, en_value)
    return unless fr_value.is_a?(String) && en_value.is_a?(String)

    fr_placeholders = placeholder_names(fr_value)
    en_placeholders = placeholder_names(en_value)
    return if fr_placeholders == en_placeholders

    "#{key} (fr: #{fr_placeholders.join(', ')} / en: #{en_placeholders.join(', ')})"
  end

  def test_every_key_present_in_both_locales_takes_the_same_placeholders
    fr = Locales.merged_for(:fr)
    en = Locales.merged_for(:en)
    shared = fr.keys & en.keys

    mismatches = shared.filter_map { |key| placeholder_mismatch(key, fr[key], en[key]) }

    assert_empty mismatches, <<~MSG
      These keys interpolate different placeholders in fr and en, so calling
      `Locales.t` with one locale's variables raises in the other:
      #{mismatches.join("\n")}

      This is a report guard, not a fixer: an existing mismatch found here on a
      key this lot did not touch is a separate ticket, not this one.
    MSG
  end

  def test_stagnation_pipeline_renders_the_infra_detail_in_both_locales
    detail = 'deploy_review (script_failure)'
    fr = Locales.t(:stagnation_pipeline, locale: :fr, tag: 't', mr_url: 'url', detail: detail)
    en = Locales.t(:stagnation_pipeline, locale: :en, tag: 't', mr_url: 'url', detail: detail)

    assert_includes fr, detail
    assert_includes en, detail
  end

  def test_activity_stagnation_and_infra_lines_render_the_detail_in_both_locales
    detail = 'deploy_review (script_failure)'
    %i[fr en].each do |loc|
      %i[activity_stagnation_pipeline activity_pipeline_infra].each do |key|
        assert_includes Locales.t(key, locale: loc, tag: 't', detail: detail), detail,
                        "#{key} (#{loc}) must interpolate the detail"
      end
    end
  end

  def test_pipeline_fix_success_with_all_vars
    msg = Locales.t(:pipeline_fix_success, locale: :en,
                                           tag: 'v1', mr_url: 'url', count: 3, round: 2)

    assert_includes msg, '3'
    assert_includes msg, '2'
    assert_includes msg, 'url'
  end

  # --- the two tables autodev posts onto GitLab are ASCII -------------------
  #
  # The convention every locale entry written in this lot follows: no accented
  # letter. It was held by nothing at all — no test in this file or in
  # `test/i18n_derived_keys_test.rb` looked at a single character — so it held by
  # habit, and a habit is not a guard.
  #
  # The perimeter is the two tables whose strings autodev **writes onto GitLab**:
  # `notifications` (the issue comments) and `activity` (the activity note it
  # edits in place). It is not every locale file, and the reason is measured, not
  # assumed: `web.fr.yml` carries accented letters on 264 lines, `devise.fr.yml`
  # on 3 and `cli.fr.yml` on 2, and `web.en.yml` carries typographic characters
  # (an ellipsis, curly quotes, `⌘`) on 20 more. Those are rendered into the
  # dashboard's HTML and the operator's terminal, never posted. Widening the rule
  # to them would mean rewriting some three hundred existing labels, which is a
  # product decision and not a guard's to take.
  #
  # That last sentence is the kind that goes stale silently — this lot produced
  # five of them — so it is pinned rather than trusted:
  # `test_the_limit_of_the_ascii_perimeter_is_still_the_reason_for_it` fails the
  # day an excluded table stops carrying what this rule forbids, and says to
  # widen the perimeter.
  #
  # Two non-ASCII characters are allowed by name. Both are typographic and
  # neither is a letter: the em dash separates a message from the detail
  # interpolated after it (`echec — %{error}`), and the arrow is how an activity
  # label names the step it is moving to. An allow-list rather than "no accented
  # letter", so a non-breaking space or a curly apostrophe pasted into a GitLab
  # comment is caught too.
  ASCII_TABLES = %w[notifications activity].freeze
  NON_ASCII_TABLES = %w[web devise cli].freeze
  ALLOWED_NON_ASCII = ['—', '→'].freeze

  def locale_files(stems)
    Dir[File.expand_path("../config/locales/{#{stems.join(',')}}.*.yml", __dir__)]
  end

  # `[path:line, character]` for every character outside the allow-list.
  def non_ascii_in(path)
    File.readlines(path, encoding: 'UTF-8').each_with_index.flat_map do |line, index|
      offending = line.each_char.reject { |char| char.ascii_only? || ALLOWED_NON_ASCII.include?(char) }
      offending.uniq.map { |char| "#{File.basename(path)}:#{index + 1} #{char.inspect}" }
    end
  end

  def test_the_tables_autodev_posts_on_gitlab_are_ascii
    files = locale_files(ASCII_TABLES)

    assert_equal 4, files.size, "the ASCII perimeter is #{files.size} files, not the 4 expected"

    offences = files.flat_map { |path| non_ascii_in(path) }

    assert_empty offences, <<~MSG
      A non-ASCII character sits in a string autodev posts onto GitLab: #{offences.join(', ')}.

      These two tables are written without accents (`Reentree`, `deja mergee`,
      `a corriger`), and every entry added by this lot follows that. Write the
      new one the same way, or — if the convention is being dropped rather than
      broken by accident — drop it here, in the same commit, with the reason.
      #{ALLOWED_NON_ASCII.join(' and ')} are allowed; nothing else is.
    MSG
  end

  # The reason the perimeter stops where it does, re-derived on every run instead
  # of being believed: a table excluded for carrying characters this rule forbids
  # and no longer carrying any is excluded for nothing, and the paragraph above
  # has gone stale.
  #
  # `cli.en.yml` and `devise.en.yml` are clean and named here rather than counted
  # as evidence — they are short English tables, so they say nothing either way
  # about whether the convention is being kept.
  ALREADY_CLEAN = %w[cli.en.yml devise.en.yml].freeze

  def test_the_limit_of_the_ascii_perimeter_is_still_the_reason_for_it
    clean = locale_files(NON_ASCII_TABLES).select { |path| non_ascii_in(path).empty? }
                                          .map { |path| File.basename(path) }

    assert_equal [], clean - ALREADY_CLEAN, <<~MSG
      These tables are outside the rule because they carry characters it forbids,
      and they no longer carry any: #{(clean - ALREADY_CLEAN).join(', ')}.

      Move them into ASCII_TABLES and shorten the paragraph above, or say there
      why they stay out.
    MSG
  end
end
