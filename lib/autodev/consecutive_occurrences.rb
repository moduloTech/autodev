# frozen_string_literal: true

require 'digest'
require 'json'

# "How many times in a row has *this* fact been true of this request", and the
# one place the answer is kept (Autodev #95).
#
# `issues.stagnation_signatures` is a JSON map of `key → { signature, count }`,
# and it now has four writers: `StagnationDetector` (the failing job set),
# `StagnationChecker` (the unresolved thread set), `MissingBaseBound` (the branch
# that is not on the remote) and `InvalidRequestBound` (the request GitLab keeps
# refusing). The first two carry their own decision and their own scope; the last
# two are boundaries mixed into both `PipelineMonitor` and `MrFixer`, they bump
# on exactly the same rule, and #91 had already written that rule out once.
# Writing it a second time for #95 is how the two drift.
#
# What is shared is the counting, never the decision — the same division
# `MrState` and `TargetBranch` draw. Each bound owns its key, its threshold, its
# log lines and its give-up reason; all four agree only on what "in a row" means:
# a signature that changes is a different fact, and it restarts the count.
module ConsecutiveOccurrences
  module_function

  # Records one occurrence of `signature` under `key` and returns how many
  # consecutive ones there have now been.
  def bump(issue, key, signature)
    data = read(issue)
    entry = bumped(data[key] || {}, Digest::SHA256.hexdigest(signature.to_s))
    data[key] = entry
    issue.update(stagnation_signatures: JSON.generate(data))
    entry['count']
  end

  def bumped(entry, signature)
    return { 'signature' => signature, 'count' => 1 } unless entry['signature'] == signature

    entry.merge('count' => (entry['count'] || 0) + 1)
  end

  # A column this module wrote itself; `{}` means "start the history over", which
  # costs one extra cycle at worst. No GitLab read sits anywhere under here.
  def read(issue)
    JSON.parse(issue.stagnation_signatures || '{}')
  rescue JSON::ParserError
    {}
  end
end
