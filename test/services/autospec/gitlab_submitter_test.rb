# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class GitlabSubmitterTest < ActiveSupport::TestCase
    # Stand-in for `Gitlab::Client`. Each `upload_file` call consumes
    # one canned response; `create_issue` always returns the same one.
    StubClient = Struct.new(:upload_responses, :issue_response, :calls) do
      def upload_file(project_path, file_path)
        calls << { kind: :upload, project: project_path, file: file_path }
        upload_responses.shift
      end

      def create_issue(project_path, title, options)
        calls << { kind: :create_issue, project: project_path, title: title, options: options }
        issue_response
      end
    end

    UploadResponse = Struct.new(:url, :markdown)
    IssueResponse  = Struct.new(:iid, :web_url)

    setup do
      @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
      @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
      @draft = AutospecDraft.create!(user: @author, project: @project,
                                     title: 'Login bug', markdown: 'Body',
                                     destination: 'human')
    end

    def stub_client(uploads: [], issue: IssueResponse.new(42, 'https://gitlab.example/group/proj/-/issues/42'))
      StubClient.new(uploads, issue, [])
    end

    def attach!(filename: 'cap.png')
      attachment = @draft.autospec_attachments.create!
      attachment.file.attach(io: StringIO.new('PNG'), filename: filename,
                             content_type: 'image/png')
      attachment
    end

    # --- happy path -------------------------------------------------

    def test_stamps_iid_url_and_submitted_at
      client = stub_client
      GitlabSubmitter.new(@draft, client: client).submit!
      @draft.reload

      assert_equal 42, @draft.gitlab_issue_iid
      assert_equal 'https://gitlab.example/group/proj/-/issues/42', @draft.gitlab_issue_url
      assert_not_nil @draft.submitted_at
    end

    def test_creates_issue_with_title_and_description
      client = stub_client
      GitlabSubmitter.new(@draft, client: client).submit!
      call = client.calls.find { |c| c[:kind] == :create_issue }

      assert_equal 'group/proj', call[:project]
      assert_equal 'Login bug', call[:title]
      assert_equal 'Body', call[:options][:description]
    end

    def test_uploads_each_attachment_and_rewrites_markdown # rubocop:disable Metrics/AbcSize
      attach!(filename: 'cap.png')
      local_url = Rails.application.routes.url_helpers
                       .rails_blob_path(@draft.autospec_attachments.first.file, only_path: true)
      @draft.update!(markdown: "Steps:\n\n![cap](#{local_url})")
      client = stub_client(uploads: [UploadResponse.new('/uploads/abc/cap.png', '![cap.png](/uploads/abc/cap.png)')])
      GitlabSubmitter.new(@draft, client: client).submit!
      issue_call = client.calls.find { |c| c[:kind] == :create_issue }

      refute_includes issue_call[:options][:description], '/rails/active_storage'
      assert_includes issue_call[:options][:description], '/uploads/abc/cap.png'
    end

    # --- destination + labels ---------------------------------------

    def test_human_destination_sends_no_labels
      client = stub_client
      GitlabSubmitter.new(@draft, client: client, config: {}).submit!
      call = client.calls.find { |c| c[:kind] == :create_issue }

      assert_equal '', call[:options][:labels]
    end

    def test_autodev_destination_attaches_labels_todo_from_project_config
      @draft.update!(destination: 'autodev')
      config = { 'projects' => [{ 'path' => 'group/proj', 'labels_todo' => ['Dev::Todo'] }] }
      client = stub_client
      GitlabSubmitter.new(@draft, client: client, config: config).submit!
      call = client.calls.find { |c| c[:kind] == :create_issue }

      assert_equal 'Dev::Todo', call[:options][:labels]
    end

    # --- guards -----------------------------------------------------

    def test_raises_when_already_submitted
      @draft.update!(submitted_at: Time.current)
      assert_raises(GitlabSubmitter::SubmissionFailed) do
        GitlabSubmitter.new(@draft, client: stub_client).submit!
      end
    end

    def test_disabled_flag_short_circuits
      GitlabSubmitter.disabled = true
      client = stub_client
      GitlabSubmitter.new(@draft, client: client).submit!

      assert_empty client.calls
      assert_nil @draft.reload.gitlab_issue_iid
    ensure
      GitlabSubmitter.disabled = false
    end
  end
end
