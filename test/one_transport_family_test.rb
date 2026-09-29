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
  FAMILY = GitlabHelpers::TRANSPORT_ERRORS.map { |klass| klass.name.split('::').last }.freeze
  QUORUM = 3

  # Split across two clauses on purpose: an HTTP refusal and a connection that
  # never opened do not count a retrigger, any later cut does (Autodev #125).
  EXEMPT = {
    'lib/autodev/pipeline_monitor/failure_handler.rb' => 'the retrigger split of Autodev #125'
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

  def named(body) = FAMILY.select { |name| body.match?(/\b#{Regexp.escape(name)}\b/) }

  def test_every_site_that_spells_the_family_spells_all_of_it
    partial = clauses.filter_map do |path, body|
      found = named(body)
      next if found.size < QUORUM || found.size == FAMILY.size || EXEMPT.key?(path)

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

  def test_every_exemption_still_names_part_of_the_family
    EXEMPT.each_key do |path|
      assert clauses.any? { |p, body| p == path && named(body).size >= 2 }, "#{path} no longer needs its exemption"
    end
  end
end
