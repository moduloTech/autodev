# frozen_string_literal: true

require 'gitlab'

module Autospec
  # Backfill an AutoSpec draft from an existing GitLab issue URL —
  # the §A "very nice to have" import path. Useful during the pilot
  # to migrate already-filed issues into the AutoSpec workflow
  # without retyping their bodies.
  #
  # The created draft starts in `drafting` with the GitLab issue's
  # title + description, then the CSM edits it like any other draft.
  # The import is one-way: nothing is written back to the source
  # GitLab issue, and there's no link tracking the lineage (could be
  # added later via a `source_url` column on the draft if a use case
  # surfaces).
  #
  # Test seam: pass `client:` and `config:` to bypass the
  # `Web.config`-driven client construction.
  class GitlabImporter
    class InvalidUrl < StandardError; end
    class ProjectNotFound < StandardError; end
    class ProjectNotVisible < StandardError; end
    class IssueNotFound < StandardError; end

    class << self
      # Test seam: when set, every GitlabImporter instance built
      # without an explicit `client:` uses this stub instead of
      # constructing the real Anthropic-style client. Mirrors the
      # `Autospec::Chat.default_client` pattern. Controller tests set
      # it in `setup` and clear in `teardown`; the service's own
      # tests pass `client:` directly via the constructor.
      attr_accessor :default_client
    end

    # GitLab issue URL shapes:
    #   https://<host>/<namespace>/<project>/-/issues/<iid>
    #   https://<host>/<namespace>/<project>/-/work_items/<iid>
    # The newer work-items UI links to `/-/work_items/<iid>`, where the
    # number is still the project-level issue IID — so both forms map to
    # the same `client.issue(path, iid)` call. The namespace can be deeply
    # nested (`group/sub/sub2/project`), so the project_path is everything
    # between the hostname and `/-/(issues|work_items)/`.
    ISSUE_URL_RE = %r{\Ahttps?://[^/]+/(?<path>.+?)/-/(?:issues|work_items)/(?<iid>\d+)/?(?:[?#].*)?\z}

    def initialize(url, user, client: nil, config: nil)
      @url    = url
      @user   = user
      @client = client || self.class.default_client
      @config = config
    end

    def call
      project_path, iid = parse!
      project = find_visible_project!(project_path)
      issue = fetch_issue!(project_path, iid)

      AutospecDraft.create!(
        user: @user, project: project,
        title: issue_title(issue),
        markdown: issue_description(issue)
      )
    end

    private

    def parse!
      match = ISSUE_URL_RE.match(@url.to_s.strip)
      raise InvalidUrl, "URL #{@url.inspect} is not a GitLab issue URL" unless match

      [match[:path], match[:iid].to_i]
    end

    def find_visible_project!(project_path)
      project = Project.find_by(gitlab_path: project_path)
      raise ProjectNotFound, "no Project row for #{project_path.inspect}" unless project
      raise ProjectNotVisible, "user ##{@user.id} cannot access #{project_path}" unless visible?(project)

      project
    end

    def visible?(project)
      @user.admin? || @user.contributor_of?(project)
    end

    def fetch_issue!(project_path, iid)
      client.issue(project_path, iid)
    rescue Gitlab::Error::NotFound
      raise IssueNotFound, "issue ##{iid} not found on #{project_path}"
    rescue Gitlab::Error::Error => e
      raise IssueNotFound, "GitLab API error: #{e.class}: #{e.message}"
    end

    def issue_title(issue)
      GitlabHelpers.field(issue, :title)
    end

    def issue_description(issue)
      GitlabHelpers.field(issue, :description).to_s
    end

    def client
      @client ||= build_client
    end

    def build_client
      cfg = config_hash
      GitlabHelpers.build_gitlab_client(cfg['gitlab_url'], cfg['gitlab_token'])
    end

    def config_hash
      @config || (defined?(::Web) && ::Web.respond_to?(:config) && ::Web.config) || {}
    end
  end
end
