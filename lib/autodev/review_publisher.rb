# frozen_string_literal: true

# Posts a review that the project's skill produced but deliberately did not write
# (Autodev #74). Uses autodev's own PAT — the credential mr-review carries has
# been answering 401 since April.
class ReviewPublisher
  MARKER = '<!-- autodev:review -->'

  def initialize(client:, project_path:, logger:, locale:)
    @client = client
    @project_path = project_path
    @logger = logger
    @locale = locale
  end

  # nil = this poll could not conclude (no diff_refs yet). Not a verdict, and not
  # a review failure: the row is left where it is and the next cycle re-reads
  # (Autodev #62).
  def publish(mr_iid:, contract:)
    if already_published?(mr_iid)
      @logger.info("MR !#{mr_iid}: review already published, not posting again")
      return { posted: 0, demoted: 0 }
    end

    refs = diff_refs(mr_iid)
    return @logger.info("MR !#{mr_iid}: diff_refs not computed yet, review not published") || nil unless refs

    posted, demoted = post_inline(mr_iid, refs, contract.inline)
    post_summary(mr_iid, contract, demoted)
    { posted: posted.size, demoted: demoted.size }
  end

  private

  def diff_refs(mr_iid)
    mr = GitlabHelpers.answer(:merge_request) { @client.merge_request(@project_path, mr_iid) }
    refs = mr.diff_refs
    return nil unless refs&.head_sha

    refs
  end

  # One at a time, and each one checked: GitLab accepts a position it cannot
  # anchor and returns a note with a null `position`. A finding that will not
  # anchor is moved into the summary comment, never dropped — the rule is the
  # reviewed project's own review skill's.
  def post_inline(mr_iid, refs, findings)
    posted = []
    demoted = []
    findings.each do |finding|
      note = post_finding(mr_iid, refs, finding)
      anchored?(note) ? posted << finding : demoted << finding
    end
    [posted, demoted]
  end

  def post_finding(mr_iid, refs, finding)
    GitlabHelpers.answer(:mr_discussion) do
      @client.create_merge_request_discussion(@project_path, mr_iid,
                                              body: finding['body'].to_s,
                                              position: position_for(finding, refs))
    end
  end

  def position_for(finding, refs)
    { position_type: 'text', base_sha: refs.base_sha, start_sha: refs.start_sha,
      head_sha: refs.head_sha, old_path: finding['file'], new_path: finding['file'],
      new_line: finding['line'].to_i }
  end

  def anchored?(note)
    first = Array(note.respond_to?(:notes) ? note.notes : nil).first
    !first.nil? && !first.position.nil?
  end

  # Posted last, so its presence means the review went all the way. A cycle that
  # dies after the discussions but before this comment is retried, and without
  # this check the retry would post the discussions a second time.
  def already_published?(mr_iid)
    notes = GitlabHelpers.answer(:mr_notes) do
      @client.merge_request_notes(@project_path, mr_iid, per_page: 100).auto_paginate
    end
    notes.any? { |n| n.body.to_s.include?(MARKER) }
  end

  def post_summary(mr_iid, contract, demoted)
    body = Locales.t(:review_summary, locale: @locale, verdict: contract.verdict,
                                      summary: summary_body(contract, demoted))
    GitlabHelpers.answer(:mr_note) { @client.create_merge_request_note(@project_path, mr_iid, body) }
  end

  def summary_body(contract, demoted)
    lines = [contract.summary]
    (contract.summary_only + demoted).each do |f|
      where = f['file'] ? " (#{f['file']}:#{f['line']})" : ''
      lines << "- **#{f['severity']}**#{where} — #{f['body']}"
    end
    lines.reject { |l| l.to_s.strip.empty? }.join("\n\n")
  end
end
