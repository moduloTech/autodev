# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/label_manager'

# Review of the alpha-56 lot — `labels_written_at` is what sends the next
# handover verdict to the label events (Autodev #101), and `manage_labels`
# swallows a cut label write. Stamped only after `edit_issue` returned, a write
# that landed but whose answer never came (a read timeout, a reset) left no
# stamp: if it had removed a human's `label_done`, `ErasedScan` never read the
# event and the handover was lost for good.
#
# A cut after the request left may have landed, so it is stamped. A connection
# that never opened, or an HTTP refusal, sent nothing, so it is not.
class ACutLabelWriteIsStillStampedTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  CONFIG = { 'path' => PATH, 'labels_todo' => ['To Do'], 'label_doing' => 'Doing',
             'label_done' => 'Done' }.freeze
  FakeIssue = Struct.new(:labels)

  # Carries `label_done`, and fails every label write with `error`.
  class CutGitlab
    def initialize(error) = @error = error
    def issue(_path, _iid) = FakeIssue.new(['Done'])
    def edit_issue(*) = raise(@error)
  end

  def setup = setup_database

  def write_under(error)
    row = create_issue(project_path: PATH, status: 'fixing_discussions')
    manager(CutGitlab.new(error)).send(:apply_label_doing, row.issue_iid)
    ::Issue.find(row.id).labels_written_at
  end

  def test_a_cut_after_the_request_left_is_stamped
    [Net::ReadTimeout.new, Errno::ECONNRESET.new, EOFError.new, OpenSSL::SSL::SSLError.new].each do |error|
      refute_nil write_under(error), "#{error.class} may have landed and left no stamp"
    end
  end

  def test_a_request_that_never_left_is_not_stamped
    response = Struct.new(:code, :parsed_response, :request).new(502, '', Struct.new(:base_uri, :path).new('x', '/'))

    [Net::OpenTimeout.new, Errno::ECONNREFUSED.new, SocketError.new,
     Gitlab::Error::BadGateway.new(response)].each do |error|
      assert_nil write_under(error), "#{error.class} sent nothing and was stamped"
    end
  end

  def test_the_cut_is_still_swallowed
    row = create_issue(project_path: PATH, status: 'fixing_discussions')

    assert_equal [], manager(CutGitlab.new(Net::ReadTimeout.new)).send(:manage_labels, row.issue_iid,
                                                                       remove: ['Done'], add: 'Doing')
  end

  private

  def manager(gitlab)
    Object.new.tap do |obj|
      obj.singleton_class.include(LabelManager)
      obj.instance_variable_set(:@client, gitlab)
      obj.instance_variable_set(:@project_config, CONFIG)
      obj.instance_variable_set(:@project_path, PATH)
      obj.instance_variable_set(:@logger, nil)
      obj.define_singleton_method(:log) { |*| nil }
      obj.define_singleton_method(:log_error) { |*| nil }
    end
  end
end
