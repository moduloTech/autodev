# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# `GET /issues/:id.json` renders the whole attribute hash, `dc_stdout` and
# `dc_stderr` included, and it did so unredacted while the HTML view of the same
# row scrubbed both (Autodev #59).
#
# Autodev #59 closed the real exposure at the *write* side — `record_output` is the
# single writer of the two buffers, so everything stored from then on is already
# clean — and scrubbed the two HTML renderers on the way out as well, which covers
# rows written before that. The JSON variant was left out. Nothing leaks today
# (the 131 rows carrying these columns were scanned against both Redactor patterns
# with no match), so this is the asymmetry rather than a live leak: two of the four
# readers assumed the columns were clean while nothing structurally guaranteed it.
#
# It is the same session, the same cookie and the same authorisation as the HTML
# page — only the `Accept` header differs — so there is no argument for treating it
# differently. The CLI `--errors` path stays verbatim on purpose: it reads the
# local database on a machine whose `~/.autodev/config.yml` already holds the PAT
# in cleartext.
class IssuesControllerJsonScrubTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  # Token-shaped, matching Redactor::GITLAB_TOKEN, and a URL carrying embedded
  # credentials — the two shapes the redactor knows and the two that actually
  # occur here (mr-review echoes the PAT; git remotes carry `oauth2:<token>@`).
  PAT = 'glpat-Abc123DEF456ghi789'
  CREDENTIALED_URL = 'https://oauth2:glpat-Secret000111222@source.modulotech.fr/group/proj.git'

  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    # Written straight onto the row, which is what a legacy row looks like: these
    # predate the write-side scrub, and they are exactly the population the
    # read-side scrub exists for.
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 700, status: 'done',
                           needs_attention: true, attention_reason: 'review_failures_exhausted',
                           dc_stdout: "=== mr-review ===\ntoken=#{PAT}\n",
                           dc_stderr: "=== mr-review ===\nfatal: could not read from #{CREDENTIALED_URL}\n")
    sign_in @admin
  end

  def test_the_json_variant_does_not_serve_a_bare_token
    get "/issues/#{@issue.id}.json"

    assert_response :success
    refute_includes response.body, PAT
    refute_includes response.body, 'glpat-Secret000111222'
  end

  def test_the_json_variant_masks_url_credentials
    get "/issues/#{@issue.id}.json"

    assert_includes JSON.parse(response.body)['dc_stderr'], 'oauth2:***@source.modulotech.fr'
  end

  # The scrub must not cost the endpoint its contract: it is consumed as JSON, and
  # a redaction that produced invalid JSON or dropped fields would be a worse bug
  # than the one being fixed.
  def test_the_response_is_still_valid_json_carrying_every_attribute
    get "/issues/#{@issue.id}.json"
    parsed = JSON.parse(response.body)

    assert_equal @issue.attributes.keys.sort, parsed.keys.sort
    assert_equal [@issue.id, 700, 'done'], [parsed['id'], parsed['issue_iid'], parsed['status']]
  end

  # Everything that is not a secret survives verbatim — the point of the columns
  # is to say why the tool gave up, and a scrub that ate the diagnosis would make
  # them useless.
  def test_the_diagnostic_content_survives
    get "/issues/#{@issue.id}.json"
    parsed = JSON.parse(response.body)

    assert_includes parsed['dc_stdout'], '=== mr-review ==='
    assert_includes parsed['dc_stderr'], 'fatal: could not read from'
  end

  # The HTML view of the same row already scrubbed; this pins that the two
  # renderers now agree, which is the whole point of the change.
  def test_html_and_json_agree_on_what_is_masked
    get "/issues/#{@issue.id}"
    html = response.body
    get "/issues/#{@issue.id}.json"

    refute_includes html, PAT
    refute_includes response.body, PAT
  end
end
