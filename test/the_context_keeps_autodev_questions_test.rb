# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/issue_processor'
require 'autodev/mr_fixer'

# Autodev #137 — the prompt context kept the answer and lost the question.
#
# `IssueFormatter.append_comments` dropped every note carrying `**autodev**`, which
# is autodev's signature on everything it posts, its own questions to the
# requester included. On POWERPANNE#14746 the spec check of 28/08/2026 read
# « 3. (b) Une interface utilisateur… » without the question of 29/06 that defined
# (a) and (b). The context now keeps autodev's questions (clarification, the #121
# functional question) and its answers to question tickets, drops its activity
# note and status notices, and lists the comments oldest first — GitLab's
# `issue_notes` answers newest first by default, so even a kept question used to
# come *after* its answer.
module ContextKeepsQuestionsFixtures
  Note = Struct.new(:id, :body, :author, :created_at, :system)
  Author = Struct.new(:name)
  GlIssue = Struct.new(:iid, :title, :description)

  class Paginated
    def initialize(items) = @items = items
    def auto_paginate = @items
  end

  # Serves the notes in GitLab's default order for this endpoint: newest first.
  class Client
    def initialize(notes) = @notes = notes
    def issue(_path, iid) = GlIssue.new(iid, 'Export mensuel', 'Description du ticket')
    def issue_notes(_path, _iid, **_opts) = Paginated.new(@notes.sort_by { |n| [n.created_at, n.id] }.reverse)
    def issue_links(_path, _iid) = []
  end

  # Serves the notes in exactly the order given, and records the options the
  # fetch asked for.
  class OrderedClient < Client
    attr_reader :options

    def issue_notes(_path, _iid, **opts)
      @options = opts
      Paginated.new(@notes)
    end
  end

  BOT = Author.new('Autodev')
  HUMAN = Author.new('Requester')

  def note(id, body, at, author: BOT, system: false)
    Note.new(id, body, author, at, system)
  end

  def context_for(notes, client: Client)
    GitlabHelpers.fetch_issue_context(client.new(notes), 'group/project', 14_746)
  end

  def tag(version = '1.0.0.alpha.32') = "**autodev** (v#{version})"

  def header(key, locale, **vars) = Locales.t(key, locale: locale, tag: tag, **vars)
end

class TheContextKeepsAutodevQuestionsTest < Minitest::Test
  include ContextKeepsQuestionsFixtures

  # The real first line and item 3 of PP#14746's note 832858 (29/06/2026), and the
  # requester's answer of note 832966, as `glab api` returned them on 21/10/2026.
  # The surrounding notices are the ones the ticket carried on 28/08.
  PP_QUESTION = <<~BODY.chomp
    :thinking: **autodev** (v1.0.0.alpha.32) : la specification necessite des precisions avant implementation.

    3. La forme de la fonctionnalité reste ambiguë. La discussion oscille entre (a) un envoi mensuel automatique programmé (proposé par Emily, conforme au pattern dedicate.rake évoqué par Lucas) et (b) une interface utilisateur permettant de choisir une période jusqu'à 1 mois (demande remontée par Bryan). Aucune décision finale n'est tranchée dans le ticket.

    Merci de repondre a ces questions dans les commentaires. L'implementation reprendra automatiquement.
  BODY
  PP_ANSWER = "3. (b) Une interface utilisateur permettant de choisir une période jusqu'à 1 mois"

  def pp14746_notes
    [
      note(832_855, ':robot: **autodev** (v1.0.0.alpha.32) : traitement en cours...', '2026-06-29T15:43:48.873+02:00'),
      note(832_858, PP_QUESTION, '2026-06-29T15:45:00.012+02:00'),
      note(832_966, PP_ANSWER, '2026-06-29T17:08:06.045+02:00', author: HUMAN),
      note(849_043, ':robot: **autodev** (v1.0.0.alpha.49) : traitement en cours...', '2026-08-28T13:02:06.503+02:00'),
      note(849_051, ':white_check_mark: **autodev** (v1.0.0.alpha.49) : MR creee : https://gitlab.example/mr/1',
           '2026-08-28T13:16:30.666+02:00'),
      note(849_100, 'changed the description', '2026-08-28T13:20:00.000+02:00', system: true)
    ]
  end

  def test_the_pp14746_question_comes_back_before_its_answer
    context = context_for(pp14746_notes)

    question_at = context.index('(a) un envoi mensuel automatique programmé')
    answer_at = context.index(PP_ANSWER)

    refute_nil question_at, 'the 29/06 clarification question is missing from the context'
    refute_nil answer_at
    assert_operator question_at, :<, answer_at, 'the answer is read before the question that defines (a) and (b)'
  end

  def test_the_pp14746_notices_stay_out
    context = context_for(pp14746_notes)

    refute_includes context, 'traitement en cours'
    refute_includes context, 'MR creee'
    refute_includes context, 'changed the description'
  end

  def test_an_english_question_and_its_answer_are_both_in_order
    question = "#{header(:spec_unclear_header, :en)}\n\n1. Which company?\n\n" \
               "#{Locales.t(:spec_unclear_footer, locale: :en)}"
    notes = [note(1, question, '2026-06-01T10:00:00Z'),
             note(2, '1. RAD', '2026-06-01T11:00:00Z', author: HUMAN)]

    context = context_for(notes)

    assert_operator context.index('1. Which company?'), :<, context.index('1. RAD')
  end

  def test_the_activity_note_and_a_failure_notice_are_not_in_the_context
    activity = "#{ActivityLogger::HEADER_PREFIX} (v1.0.0.alpha.57) — Journal d'activite\n\n" \
               '- `06-18 10:08` — :rocket: Traitement demarre'
    failure = header(:error_generic, :fr, error: 'ImplementationError: danger-claude -p failed')
    notes = [note(1, activity, '2026-06-18T10:08:34Z'),
             note(2, failure, '2026-06-18T10:10:44Z'),
             note(3, 'Toujours KO', '2026-06-18T11:00:00Z', author: HUMAN)]

    context = context_for(notes)

    refute_includes context, 'Journal d'
    refute_includes context, 'ImplementationError'
    assert_includes context, 'Toujours KO'
  end

  def test_an_unmarked_functional_question_is_kept_whatever_its_mention
    question = "#{header(:functional_question_header, :fr, mention: '@alves_b ', mr_iid: 11_409, count: 2)}" \
               "\n\n1. Le filtre de dates manque."

    assert_includes context_for([note(1, question, '2026-08-29T10:00:00Z')]), 'Le filtre de dates manque.'
  end

  def test_an_unmarked_answer_to_a_question_ticket_is_kept
    answer = "#{header(:question_answered_header, :en)}\n\nThe export runs nightly.\n\n---\n" \
             "#{Locales.t(:question_answered_footer, locale: :en)}"

    assert_includes context_for([note(1, answer, '2026-08-29T10:00:00Z')]), 'The export runs nightly.'
  end

  # The marker is recognised first: a note whose header no longer matches any
  # wording on record still comes back once it carries it.
  def test_a_marked_note_is_kept_whatever_its_first_line
    body = ":thinking: **autodev** (v9.9.9) : a header nobody wrote yet\n\n1. Q?\n\n#{ContextNotes::QUESTION_MARKER}"

    assert_includes context_for([note(1, body, '2026-08-29T10:00:00Z')]), '1. Q?'
  end

  # Only the first line is a header. A status notice is not a question because a
  # question header appears further down in it.
  def test_a_notice_quoting_a_question_header_below_its_first_line_is_dropped
    body = "#{header(:error_generic, :fr, error: 'boom')}\n#{header(:spec_unclear_header, :fr)}"

    refute_includes context_for([note(1, body, '2026-08-29T10:00:00Z')]), 'boom'
  end

  # A header followed by something else on the same line is not that header.
  def test_a_header_prefix_alone_is_not_enough
    body = "#{header(:question_answered_header, :fr)} — et autre chose"

    refute_includes context_for([note(1, body, '2026-08-29T10:00:00Z')]), 'autre chose'
  end
end

# GitLab's `issue_notes` answers newest first by default; the context lists the
# comments oldest first, so an answer follows its question.
class TheContextIsChronologicalTest < Minitest::Test
  include ContextKeepsQuestionsFixtures

  def test_human_comments_are_listed_oldest_first
    notes = [note(1, 'premier', '2026-06-01T10:00:00Z', author: HUMAN),
             note(2, 'second', '2026-06-02T10:00:00Z', author: HUMAN),
             note(3, 'troisieme', '2026-06-03T10:00:00Z', author: HUMAN)]

    context = context_for(notes)

    assert_operator context.index('premier'), :<, context.index('second')
    assert_operator context.index('second'), :<, context.index('troisieme')
  end

  # Two pages of notes do not arrive as an exact reversal: the order is decided
  # here, not inherited from what GitLab sent.
  def test_notes_served_in_no_particular_order_come_out_chronological
    notes = [note(2, 'n2', '2026-06-02T10:00:00Z', author: HUMAN), note(4, 'n4', '2026-06-04T10:00:00Z', author: HUMAN),
             note(1, 'n1', '2026-06-01T10:00:00Z', author: HUMAN), note(3, 'n3', '2026-06-03T10:00:00Z', author: HUMAN)]

    context = context_for(notes, client: OrderedClient)

    assert_equal %w[n1 n2 n3 n4], context.scan(/^n\d$/)
  end

  # Instants, not strings: across the 25/10 DST change, 02:10+01:00 (01:10Z) is
  # after 02:30+02:00 (00:30Z), though it sorts first as text.
  def test_the_order_compares_instants_not_strings
    notes = [note(2, 'apres', '2026-10-25T02:10:00.000+01:00', author: HUMAN),
             note(1, 'avant', '2026-10-25T02:30:00.000+02:00', author: HUMAN)]

    context = context_for(notes, client: OrderedClient)

    assert_operator context.index('avant'), :<, context.index('apres')
  end

  def test_the_note_id_breaks_a_tie_on_the_instant
    notes = [note(20, 'vingt', '2026-06-01T10:00:00Z', author: HUMAN),
             note(10, 'dix', '2026-06-01T10:00:00Z', author: HUMAN)]

    context = context_for(notes, client: OrderedClient)

    assert_operator context.index('dix'), :<, context.index('vingt')
  end

  # The fetch stays the very request `HumanActivity` makes on this endpoint.
  def test_the_fetch_asks_for_no_order
    client = OrderedClient.new([])
    GitlabHelpers.fetch_issue_context(client, 'group/project', 14_746)

    assert_equal({ per_page: 100 }, client.options)
  end
end

# What is and is not a kept autodev note, at the edges.
class TheContextRecognisesAutodevQuestionsTest < Minitest::Test
  include ContextKeepsQuestionsFixtures

  PP_QUESTION = TheContextKeepsAutodevQuestionsTest::PP_QUESTION

  # A quoted header is not a header: the whole first line has to be one.
  def test_a_human_note_quoting_a_question_header_is_dropped
    body = "> #{header(:spec_unclear_header, :fr)}\n\nje cite"

    refute_includes context_for([note(1, body, '2026-08-29T10:00:00Z', author: HUMAN)]), 'je cite'
  end

  # The signature is looked for in the whole body, as before #137.
  def test_a_human_note_quoting_a_notice_below_its_first_line_is_dropped
    body = "Voir ci-dessous :\n> #{header(:error_generic, :fr, error: 'boom')}"

    refute_includes context_for([note(1, body, '2026-08-29T10:00:00Z', author: HUMAN)]), 'Voir ci-dessous'
  end

  def test_a_question_preceded_by_blank_lines_is_kept
    body = "\n\n#{header(:spec_unclear_header, :fr)}\n\n1. Laquelle ?"

    assert_includes context_for([note(1, body, '2026-08-29T10:00:00Z')]), '1. Laquelle ?'
  end

  # A kept autodev note is rendered like any comment, its body verbatim — marker
  # included.
  def test_a_kept_question_is_rendered_like_a_comment
    marked = "#{PP_QUESTION}\n\n#{ContextNotes::QUESTION_MARKER}"
    context = context_for([note(832_858, marked, '2026-06-29T15:45:00.012+02:00')])

    assert_includes context, "### Autodev (2026-06-29T15:45:00.012+02:00)\n#{marked}\n"
  end

  # `HumanActivity` still reads autodev's question as autodev talking: it is not
  # the requester's answer that resumes a parked request.
  def test_autodev_s_question_is_still_not_a_human_note
    host = IssueProcessor.allocate
    bodies = []
    host.define_singleton_method(:notify_issue) { |_iid, body| bodies << body }
    host.define_singleton_method(:issue_locale) { |_iid| :fr }
    host.send(:notify_clarification_questions, ['Quelle societe ?'], 1)

    refute HumanActivity.human_note_after?(note(1, bodies.first, '2026-08-29T10:00:00Z'), Time.parse('2026-08-28'))
  end
end

# The patterns are derived from the locale table, not restated: every kept key in
# both locales yields one, and each matches the header it describes.
class ContextNotesDerivationTest < Minitest::Test
  include ContextKeepsQuestionsFixtures

  VARS = { mention: '@someone ', mr_iid: 12, count: 3 }.freeze

  def test_every_kept_header_in_both_locales_has_a_pattern
    assert_equal ContextNotes::KEPT_HEADER_KEYS.size * ContextNotes::LOCALES.size, ContextNotes.header_patterns.size
  end

  def test_each_kept_header_is_recognised_in_both_locales_with_and_without_a_version
    ContextNotes::KEPT_HEADER_KEYS.product(ContextNotes::LOCALES).each do |key, locale|
      ['**autodev**', tag('1.0.0.alpha.57')].each do |signature|
        body = "#{Locales.t(key, locale: locale, tag: signature, **VARS)}\n\nbody"

        assert ContextNotes.in_context?(Note.new(1, body, BOT, '2026-01-01T00:00:00Z', false)),
               "#{key} (#{locale}) with #{signature} is not recognised"
      end
    end
  end

  def test_the_kept_kinds_are_exactly_the_three_the_owner_named
    assert_equal %i[spec_unclear_header functional_question_header question_answered_header],
                 ContextNotes::KEPT_HEADER_KEYS
  end

  # Every other note autodev can post stays out: each notification template
  # rendered as posted, and each activity entry as a line of the activity note.
  def test_no_other_notification_or_activity_template_is_kept
    kept = %w[notifications activity].product(ContextNotes::LOCALES).flat_map { |table, locale| kept_in(table, locale) }

    assert_empty kept
  end

  def kept_in(table, locale)
    path = File.expand_path("../config/locales/#{table}.#{locale}.yml", __dir__)
    YAML.safe_load_file(path)[locale.to_s].filter_map do |key, template|
      next if ContextNotes::KEPT_HEADER_KEYS.include?(key.to_sym)

      note = Note.new(1, as_posted(template), BOT, '2026-01-01', false)
      "#{table}.#{locale}.#{key}" if ContextNotes.in_context?(note)
    end
  end

  # A notification as posted; an activity entry as a line of the activity note.
  def as_posted(template)
    body = template.to_s.gsub(/%\{(\w+)\}/) { ::Regexp.last_match(1) == 'tag' ? tag('1.0.0.alpha.57') : 'X' }
    body.include?('**autodev**') ? body : "#{ActivityLogger::HEADER_PREFIX} (v1.0.0.alpha.57)\n#{body}"
  end

  # Derived, not restated: a reworded header is what the patterns follow.
  def test_the_patterns_follow_the_locale_table
    reworded = Locales.lookup(:fr, :spec_unclear_header).sub('necessite des precisions', 'demande a etre precisee')
    lookup = ->(locale, key) { key == :spec_unclear_header && locale == :fr ? reworded : nil }
    body = "#{I18n.interpolate(reworded, tag: tag)}\n\n1. Q"
    old = "#{Locales.t(:spec_unclear_header, locale: :fr, tag: tag)}\n\n1. Q"

    with_fresh_patterns do
      Locales.stub(:lookup, lookup) do
        assert ContextNotes.in_context?(Note.new(1, body, BOT, '2026-01-01', false))
        refute ContextNotes.in_context?(Note.new(1, old, BOT, '2026-01-01', false))
      end
    end
  end

  def with_fresh_patterns
    ContextNotes.instance_variable_set(:@header_patterns, nil)
    yield
  ensure
    ContextNotes.instance_variable_set(:@header_patterns, nil)
  end

  def test_a_system_note_is_never_in_the_context
    refute ContextNotes.in_context?(Note.new(1, "x #{ContextNotes::QUESTION_MARKER}", HUMAN, '2026-01-01', true))
  end
end

# The three writers put the marker on what they post, so a later rewording of a
# header does not lose the notes posted after it.
class AutodevQuestionsCarryTheContextMarkerTest < Minitest::Test
  include ContextKeepsQuestionsFixtures

  def recording(klass)
    bodies = []
    host = klass.allocate
    host.define_singleton_method(:notify_issue) { |_iid, body| bodies << body }
    host.define_singleton_method(:issue_locale) { |_iid| :fr }
    host.define_singleton_method(:finalize_question) { |*| nil }
    [host, bodies]
  end

  def kept?(body) = ContextNotes.in_context?(Note.new(1, body, BOT, '2026-01-01T00:00:00Z', false))

  def test_the_clarification_questions_carry_the_question_marker
    host, bodies = recording(IssueProcessor)
    host.send(:notify_clarification_questions, ['Quelle societe ?'], 1)

    assert bodies.first.end_with?(ContextNotes::QUESTION_MARKER)
  end

  def test_the_answer_to_a_question_carries_the_answer_marker
    host, bodies = recording(IssueProcessor)
    host.send(:post_answer, 1, Struct.new(:id).new(1), 'La reponse')

    assert bodies.first.end_with?(ContextNotes::ANSWER_MARKER)
  end

  def test_the_functional_question_carries_the_question_marker
    fix = MrFixer.allocate
    fix.instance_variable_set(:@project_path, 'group/project')
    issue = Struct.new(:locale, :mr_iid).new('fr', 11_409)
    body = fix.send(:functional_question_body, issue, [], Struct.new(:author).new(nil))

    assert body.end_with?(ContextNotes::QUESTION_MARKER)
  end

  # Marker first: with every header pattern gone, the marked bodies still pass.
  def test_a_marked_body_is_kept_even_with_no_header_pattern
    host, bodies = recording(IssueProcessor)
    host.send(:notify_clarification_questions, ['Q'], 1)

    ContextNotes.stub(:header_patterns, []) { assert kept?(bodies.first) }
  end

  def test_a_status_notice_carries_no_marker
    notice = Locales.t(:processing_started, locale: :fr, tag: tag)

    refute kept?(notice)
  end
end
