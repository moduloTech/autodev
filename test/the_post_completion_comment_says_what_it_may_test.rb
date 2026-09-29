# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'post_completion_fixtures'

# Autodev #94. What the comment a failed `post_completion` posts may say — the
# command, the merge request, that the delivery stands, how to replay, in the
# ticket's language — and what it never says: the command's output, or a
# credential sitting in one of its arguments.
class ThePostCompletionCommentSaysWhatItMayTest < Minitest::Test
  include DatabaseTestHelper
  include PostCompletionFailureFixtures

  def test_the_comment_names_the_command_and_the_merge_request
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    assert_includes comments.first, '`sh -c exit 3`'
    assert_includes comments.first, @issue.mr_url
    refute_predicate @issue.reload, :needs_attention
  end

  def test_the_comment_says_the_delivery_stands_and_how_to_replay
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 1'])

    assert_includes comments.first, Locales.t(:post_completion_failed_footer, locale: :en)
  end

  def test_the_comment_follows_the_ticket_locale
    @issue.update!(locale: 'fr')
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 3'])

    assert_includes comments.first, 'termin' # "s'est terminee avec le code 3"
    assert_includes comments.first, Locales.t(:post_completion_failed_footer, locale: :fr)
  end

  def test_the_comment_never_carries_the_command_output
    monitor.run_post_completion(@issue, ['sh', '-c', "#{PRINTS_MARKER}; #{PRINTS_MARKER} >&2; exit 2"])

    assert_includes @issue.reload.post_completion_error, "stdout: #{MARKER}"
    assert_includes @issue.post_completion_error, "stderr: #{MARKER}"
    refute_includes comments.first, MARKER
  end

  def test_the_command_is_scrubbed_before_it_is_published
    monitor.run_post_completion(@issue, ['sh', '-c', 'exit 4', "https://oauth2:#{SECRET}@gitlab.example/x.git"])

    assert_equal 1, comments.size
    refute_includes comments.first, SECRET
  end
end
