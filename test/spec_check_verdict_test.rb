# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'tmpdir'

# Autodev #122. Nothing drove `check_specification` / `parse_spec_result`
# before: the prompt was rewritten to block more often, and what the code makes
# of the answer is what decides whether a request is parked with its questions
# or implemented anyway. Each case below goes through the real method, from the
# text danger-claude returns to the row's status and the comment posted.
#
# The direction of every fallback is pinned as it is: an answer the parser
# cannot read *proceeds* to implementation. That is the pre-#122 behaviour and
# this ticket does not change it; the tests make it visible.
class SpecCheckVerdictTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Doing', 'label_done' => 'Done' }.freeze
  CONFIG = { 'gitlab_url' => 'https://gitlab.example', 'gitlab_token' => 'x' }.freeze

  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  # Records the comments posted; every other GitLab call answers something
  # inert, so the paths after the verdict run without reaching the network.
  class Client
    attr_reader :notes

    def initialize = @notes = []
    def issue(_path, _iid) = Struct.new(:labels, :state, :author, :assignees).new(['To do'], 'opened', nil, [])
    def issue_notes(*, **) = Paginated.new([])

    def create_issue_note(_path, _iid, body)
      @notes << body
      Struct.new(:id).new(@notes.size)
    end

    def edit_issue_note(*) = nil
    def edit_issue(*, **) = nil
    def user = Struct.new(:id).new(1)
  end

  def setup
    setup_database
    @client = Client.new
    @issue = create_issue(status: 'pending', branch_name: 'autodev/1-x')
    @issue.start_processing!
    @issue.clone_complete!
  end

  # Runs the spec check with danger-claude answering `outputs` in order; returns
  # check_specification's own value (true = the request stops here).
  def check(*outputs)
    queue = outputs.dup
    @calls = []
    processor = IssueProcessor.new(client: @client, config: CONFIG, project_config: PROJECT_CONFIG,
                                   logger: StubLogger.new, token: 'x')
    calls = @calls
    processor.define_singleton_method(:danger_claude_prompt) do |_dir, prompt, **opts|
      calls << [prompt, opts]
      queue.shift || ''
    end
    Dir.mktmpdir { |dir| processor.send(:check_specification, dir, '# ctx', @issue.issue_iid, @issue) }
  end

  def test_implementation_proceeds
    halted = check('{"type": "implementation", "issues": []}')

    refute halted
    assert_equal 'implementing', @issue.reload.status
  end

  def test_unclear_with_issues_parks_the_request_and_posts_them_numbered
    halted = check('{"type": "unclear", "issues": ["Quel ecran ?", "Telechargement ou email ?"]}')

    assert halted
    question = @client.notes.find { |n| n.include?('Quel ecran ?') }

    assert question, 'the questions must be posted on the ticket'
    assert_includes question, "1. Quel ecran ?\n2. Telechargement ou email ?"
  end

  def test_unclear_stamps_the_clarification_clock
    check('{"type": "unclear", "issues": ["Quel ecran ?"]}')

    refute_nil @issue.reload.clarification_requested_at
  end

  # An "unclear" verdict that names nothing has nothing to ask: proceeding is the
  # only move that does not post an empty question.
  def test_unclear_without_issues_proceeds
    halted = check('{"type": "unclear", "issues": []}')

    refute halted
    assert_equal 'implementing', @issue.reload.status
  end

  def test_question_goes_to_the_answering_path
    halted = check('{"type": "question", "issues": []}', 'La reponse.')

    assert halted
    assert_includes %w[answering_question done], @issue.reload.status
    assert_includes @calls[1][0], 'pose une question'
  end

  # The model does not always obey "UNIQUEMENT un objet JSON".
  def test_prose_around_the_verdict_is_tolerated
    halted = check("Apres lecture :\n{\"type\": \"unclear\", \"issues\": [\"Quel ecran ?\"]}\nVoila.")

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
  end

  def test_a_verdict_in_a_markdown_fence_is_read
    halted = check("```json\n{\"type\": \"unclear\", \"issues\": [\"Quel ecran ?\"]}\n```")

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
  end

  def test_an_unreadable_answer_proceeds
    halted = check('Je ne sais pas.')

    refute halted
    assert_equal 'implementing', @issue.reload.status
  end

  def test_the_legacy_clear_false_shape_parks_the_request
    halted = check('{"clear": false, "issues": ["Quel ecran ?"]}')

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
  end

  def test_the_legacy_clear_true_shape_proceeds
    halted = check('{"clear": true, "issues": []}')

    refute halted
    assert_equal 'implementing', @issue.reload.status
  end

  # The verdict is chosen by the "type" key, not by the first word that looks
  # like one: an "unclear" answer whose question quotes "implementation" parks.
  def test_the_type_key_decides_not_a_word_in_the_questions
    halted = check('{"type": "unclear", "issues": ["L\'implementation doit-elle remplacer l\'envoi ?"]}')

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
  end

  # The new prompt asks the model to quote what contradicts or is missing, and a
  # ticket quotes templates: a brace inside a question used to defeat the
  # brace-free regex, and the request was implemented without its questions.
  def test_a_brace_inside_a_question_still_parks_the_request
    halted = check('{"type": "unclear", "issues": ["Le gabarit {date} doit-il etre remplace ?"]}')

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
    assert(@client.notes.any? { |n| n.include?('Le gabarit {date} doit-il etre remplace ?') })
  end

  # A model that restates the prompt's schema before answering: the schema line
  # is not a verdict, the object after it is.
  def test_a_restated_schema_is_not_read_as_the_verdict
    halted = check("Structure : {\"type\": \"implementation\" | \"question\" | \"unclear\", \"issues\": []}\n" \
                   '{"type": "unclear", "issues": ["Quel ecran ?"]}')

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
  end

  # Two well-formed objects: the last one is the answer the model ended on.
  def test_the_last_verdict_is_the_answer
    halted = check('Exemple : {"type": "implementation", "issues": []}. ' \
                   'Ma reponse : {"type": "unclear", "issues": ["Quel ecran ?"]}')

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
  end

  # An object that is not a verdict (a quoted payload) is skipped, not read as
  # "unparsable".
  def test_an_object_without_a_known_type_is_skipped
    halted = check('{"type": "unclear", "issues": ["Quel ecran ?"]} {"note": "fin"}')

    assert halted
    assert_equal 'needs_clarification', @issue.reload.status
  end
end
