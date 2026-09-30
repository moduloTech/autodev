# frozen_string_literal: true

require_relative 'rails_helper'

# One transport family, spelled out at every site (the alpha-56 lot's
# integration review).
#
# `GitlabHelpers::TRANSPORT_ERRORS` is the definition of "a GitLab call that did
# not produce an answer". Seven rescue sites spell its classes out by hand
# instead of splatting the constant, on purpose: the Autodev #62/#119 scanner in
# `test/api_failure_is_not_a_verdict_test.rb` reads literal class names. Nothing
# kept those copies equal to the constant, and #125 and #126 each widened the
# same rescue on their own branch. This test is what keeps them one family: a
# rescue clause, or an `*_ERRORS = [...]` literal, that names at least three of
# the six classes must name all six.
class OneTransportFamilyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  FAMILY = GitlabHelpers::TRANSPORT_ERRORS.map(&:name).freeze
  QUORUM = 3

  # Split across two clauses on purpose: an HTTP refusal and a connection that
  # never opened do not count a retrigger, any later cut does (Autodev #125).
  # Exempt is that one clause, by the exact classes it names — a new partial
  # clause in the same file is not — and its file's clauses together must still
  # name the whole family (`test_an_exempt_split_still_covers_the_family`).
  #
  # `LabelManager#send_labels` splits the same way for its own reason: a label
  # write whose answer never came is stamped as written (Autodev #101), one
  # that never left is not. `manage_labels` still swallows the whole family.
  EXEMPT = {
    'lib/autodev/pipeline_monitor/failure_handler.rb' =>
      %w[SystemCallError Timeout::Error OpenSSL::SSL::SSLError EOFError],
    'lib/autodev/label_manager.rb' =>
      %w[SystemCallError Timeout::Error OpenSSL::SSL::SSLError EOFError]
  }.freeze

  # Each clause runs from `rescue` (or the constant) to the `=>` or the closing
  # bracket, across line continuations.
  CLAUSE = /(?:^[ \t]*rescue\b|\b[A-Z_]+_ERRORS[ \t]*=[ \t]*\[)(?<body>(?:[^\n]*,[ \t]*\n)*[^\n]*)/

  def clauses
    Dir[File.join(ROOT, '{app,lib}/**/*.rb')].flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      File.read(path).scan(CLAUSE).map { |(body)| [relative, body] }
    end
  end

  # Fully qualified, with or without the leading `::`: `Error` alone would match
  # `Gitlab::Error::ResponseError`.
  def named(body) = FAMILY.select { |name| body.match?(/(?<![\w:])(?:::)?#{Regexp.escape(name)}\b/) }

  def test_every_site_that_spells_the_family_spells_all_of_it
    partial = clauses.filter_map do |path, body|
      found = named(body)
      next if found.size < QUORUM || found.size == FAMILY.size || EXEMPT[path] == found

      "#{path}: missing #{(FAMILY - found).join(', ')}"
    end

    assert_empty partial, 'a hand-spelled transport family drifted from GitlabHelpers::TRANSPORT_ERRORS'
  end

  # The scanner must see the sites it exists for, or it proves nothing.
  def test_the_scanner_finds_the_hand_spelled_sites
    sites = clauses.select { |_, body| named(body).size == FAMILY.size }.map(&:first).uniq

    %w[lib/autodev/issue_notifier.rb lib/autodev/mr_fixer.rb lib/autodev/label_manager.rb
       app/services/autodev/external_state.rb app/services/autodev/clarification_reach.rb].each do |path|
      assert_includes sites, path
    end
  end

  def test_every_exemption_still_matches_its_clause
    EXEMPT.each do |path, names|
      assert clauses.any? { |p, body| p == path && named(body) == names }, "#{path} no longer needs its exemption"
    end
  end

  def test_an_exempt_split_still_covers_the_family
    EXEMPT.each_key do |path|
      union = clauses.select { |p, _| p == path }.flat_map { |_, body| named(body) }.uniq

      assert_equal FAMILY.sort, union.sort, "#{path}'s clauses together no longer name the whole family"
    end
  end
end
