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
# log lines and its give-up reason; the two agree only on what "in a row" means.
#
# ## What "in a row" counts, exactly (neutral review of Autodev #95, constat 3)
#
# A run of **occurrences**, not of polls. Only `bump` writes here, so a cycle in
# which the fact was not true writes nothing: it neither adds to the count nor
# clears it, and nothing else empties `stagnation_signatures` outside a human
# re-arm. Five occurrences of the same signature spread over months, with healthy
# cycles between them, therefore reach the bound.
#
# That is deliberate and it is #91's behaviour, kept: the two facts these bounds
# count — a branch the remote does not have, a request GitLab refuses — are
# deterministic, each occurrence costs a clone or a full review, and clearing the
# count on a good cycle would let a fact that alternates with success cost that for
# ever. What it forbids is a *sentence* built on the other reading: the number this
# returns may not be handed to a human as "n polls in a row", and neither bound's
# sinks say it is.
module ConsecutiveOccurrences
  module_function

  # Records one occurrence of `signature` under `key` and returns how many
  # consecutive ones there have now been — consecutive among the occurrences
  # recorded under that key, which is the only sequence this module sees.
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
