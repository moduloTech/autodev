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

  # `GitlabHelpers.field`, not the bare reader: `Gitlab::ObjectifiedHash#method_missing`
  # calls `super` for a key the response does not carry, so `mr.diff_refs` raises
  # `NoMethodError` on a response that simply has no `diff_refs` yet — which is the
  # very case this method exists to report as nil. House style, and the helper
  # exists for exactly this shape.
  def diff_refs(mr_iid)
    mr = GitlabHelpers.answer(:merge_request) { @client.merge_request(@project_path, mr_iid) }
    refs = GitlabHelpers.field(mr, :diff_refs)
    return nil unless refs&.head_sha

    refs
  end

  # One at a time, and each one checked: GitLab accepts a position it cannot
  # anchor and returns a note with a null `position`. A finding that will not
  # anchor is moved into the summary comment, never dropped — the rule is the
  # reviewed project's own review skill's.
  #
  # There are **two** ways GitLab declines a position, and until Autodev #95 this
  # only knew the polite one. The other is a flat `400 Bad request - Note
  # {:line_code=>[…]}`, which is what a merge request in conflict answers to every
  # position it is handed, because its diff has no resolvable line codes. Same
  # fact, same answer: demote the finding. See `post_finding`.
  def post_inline(mr_iid, refs, findings)
    posted = []
    demoted = []
    findings.each do |finding|
      note = post_finding(mr_iid, refs, finding)
      anchored?(note) ? posted << finding : demoted << finding
    end
    [posted, demoted]
  end

  # `nil` = not anchored, which `post_inline` reads as "demote it", exactly as it
  # reads a note GitLab returned with a null position (Autodev #95).
  #
  # The rescue is narrow by construction: `InvalidRequestError` is only ever built
  # for the statuses `GitlabHelpers::INVALID_REQUEST_STATUSES` names, so a 500, a
  # timeout, a reset connection and a dead credential all leave as
  # `ApiUnavailableError` and abort the publication — an outage must not be
  # answered by silently downgrading a review that could have been posted
  # properly on the next cycle.
  #
  # The fallback is this class's rather than its caller's because this is the only
  # object that knows what it was trying to post. A review that produced its
  # findings must not lose them because it cannot pin them to a line: the human
  # reviewer reads them in the summary comment, and the review counts as the
  # success it was.
  def post_finding(mr_iid, refs, finding)
    GitlabHelpers.answer(:mr_discussion) do
      @client.create_merge_request_discussion(@project_path, mr_iid,
                                              body: finding['body'].to_s,
                                              position: position_for(finding, refs))
    end
  rescue InvalidRequestError => e
    @logger.info("MR !#{mr_iid}: GitLab refused the position for #{finding['file']}:#{finding['line']} " \
                 "(#{e.message}); the finding moves to the summary comment")
    nil
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

  # The summary comment is posted last, so its presence means the review went all
  # the way — and this check is what keeps a retry from doubling **the comment**,
  # which is all the spec ever promised of it.
  #
  # It is not a general idempotence guard, and this comment used to say it was. A
  # cycle that dies on the second of two discussions has written no marker, so the
  # retry re-posts the first and the MR ends up with `["f1", "f1", "f2"]`. Nothing
  # here prevents that: the marker only exists once `post_summary` has run, i.e.
  # once the review already completed. The behaviour is compliant — no finding is
  # lost, and `MrFixer` resolves each thread it fixes — but a reader who believed
  # the old sentence would not go looking for the duplicate.
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
      lines << "- **#{f['severity']}**#{location_suffix(f)} — #{f['body']}"
    end
    lines.reject { |l| l.to_s.strip.empty? }.join("\n\n")
  end

  # A finding may carry a file with no line — legal in the contract, and the only
  # thing that makes it summary-only rather than inline. Rendering both
  # unconditionally produced `(app/x.rb:)`, a dangling colon over the field that
  # is missing.
  def location_suffix(finding)
    return '' unless finding['file']
    return " (#{finding['file']})" unless finding['line']

    " (#{finding['file']}:#{finding['line']})"
  end
end
