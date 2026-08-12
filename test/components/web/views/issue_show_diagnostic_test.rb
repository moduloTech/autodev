# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# The captured diagnostic is rendered on the request it belongs to (Autodev #59).
#
# #49 persisted `dc_stdout` / `dc_stderr` on the review give-up so the reason a
# `mr-review` failed would outlive log rotation — and then nothing showed it. A
# delivered-but-flagged request (`done` + `needs_attention`, e.g.
# `review_failures_exhausted`) said a review had failed and never said why, with
# the answer sitting on the row. On the 131 production rows that carry output the
# answer is often a single line ("Unexpected error: Token was revoked."), which is
# exactly what an operator needs and could not see.
#
# Same collapsible pattern as the watch cards on the /issues tabs
# (`technical-details` / `technical-summary` / `technical-pre`), and scrubbed at
# render too: rows written before the capture-path scrub landed still hold raw
# output.
class IssueShowDiagnosticTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  TOKEN = 'glpat-Abc123DEF456ghi789'
  TITLE = 'Diagnostic technique'
  STDOUT_LABEL = 'Afficher la sortie standard (stdout)'
  STDERR_LABEL = "Afficher la sortie d'erreur (stderr)"

  def setup
    setup_database
  end

  def render_show(issue, locale: :fr)
    Web::Views::IssueShow.new(
      issue: issue.attributes.symbolize_keys,
      issue_model: issue,
      events: [],
      kpis: Hash.new(0),
      can_close: false,
      locale: locale,
      csrf_token: 'test-token'
    ).call
  end

  # The raw-data card at the bottom of the page dumps every column as JSON, so a
  # bare `assert_includes html, 'unknown option -H'` would pass with no section
  # at all. Slice the page between this card's title and the raw-data card's,
  # which sits right after it in the same column.
  def diagnostic_section(html)
    html[/#{TITLE}.*?(?=Données brutes)/m].to_s
  end

  def flagged_issue(**attrs)
    create_issue(status: 'done', needs_attention: true,
                 attention_reason: 'review_failures_exhausted', **attrs)
  end

  def test_a_flagged_delivered_request_shows_both_captured_streams
    section = diagnostic_section(
      render_show(flagged_issue(dc_stdout: "=== mr-review ===\nunknown option -H\n",
                                dc_stderr: "=== mr-review ===\nToken was revoked.\n"))
    )

    assert_includes section, 'unknown option -H'
    assert_includes section, 'Token was revoked.'
  end

  # The pattern, not a new one: the errors/waiting/delivered_review cards fold
  # their technical output into these exact classes.
  def test_the_streams_are_folded_into_the_errors_page_collapsible
    section = diagnostic_section(render_show(flagged_issue(dc_stdout: 'captured output')))

    assert_includes section, 'technical-details'
    assert_includes section, 'technical-summary'
    assert_includes section, 'technical-pre'
  end

  # A delivered request that needed no human is not a diagnostic page.
  def test_a_plain_delivered_request_shows_no_diagnostic_section
    refute_includes render_show(create_issue(status: 'done', dc_stdout: 'routine output')), TITLE
  end

  # `needs_attention` is set on a non-terminal row too (`dormant_exhausted`),
  # where the captured output is whatever the last phase happened to leave
  # behind — not a verdict on the request.
  def test_an_unfinished_flagged_request_shows_no_diagnostic_section
    issue = create_issue(status: 'error', needs_attention: true,
                         attention_reason: 'dormant_exhausted', dc_stdout: 'stale output')

    refute_includes render_show(issue), TITLE
  end

  def test_a_flagged_request_with_no_captured_output_shows_no_diagnostic_section
    refute_includes render_show(flagged_issue(dc_stdout: '', dc_stderr: "\n")), TITLE
  end

  def test_an_empty_stream_is_omitted_rather_than_rendered_blank
    html = render_show(flagged_issue(dc_stdout: 'only stdout spoke', dc_stderr: ''))

    assert_includes html, STDOUT_LABEL
    refute_includes html, STDERR_LABEL
  end

  # Every writer scrubs since Autodev #59, but the rows already in the database
  # were written raw — so the read side scrubs too rather than trusting its input.
  def test_a_legacy_row_written_before_the_capture_scrub_is_redacted_at_render
    html = render_show(flagged_issue(dc_stdout: "Authorization: Bearer #{TOKEN}",
                                     dc_stderr: "https://oauth2:#{TOKEN}@source.example.fr/g/p.git"))

    refute_includes html, TOKEN, 'a legacy raw row must not publish its PAT to the dashboard'
    assert_includes diagnostic_section(html), 'https://oauth2:***@source.example.fr/g/p.git'
  end

  # The raw-data card renders `JSON.pretty_generate` of every column, so it has
  # been publishing these two verbatim since they existed — including on a row
  # this section deliberately does not surface.
  def test_the_raw_data_card_does_not_publish_a_legacy_token_either
    html = render_show(create_issue(status: 'error', dc_stderr: "fatal: #{TOKEN}"))

    refute_includes html, TOKEN
  end

  # Hardcoded literals in Phlex views are the recurring defect in this repo.
  def test_the_section_is_localized
    issue = flagged_issue(dc_stdout: 'output')

    assert_includes render_show(issue, locale: :en), 'Technical diagnostic'
    assert_includes render_show(issue, locale: :fr), TITLE
  end
end
