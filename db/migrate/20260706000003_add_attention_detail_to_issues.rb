# frozen_string_literal: true

# Adds the concrete "what actually blocked it" detail to a needs_attention row.
#
# `attention_reason` already stores which give-up path fired (e.g.
# `stagnation_pipeline`), but that is generic — the operator still had to open
# GitLab and dig through the pipeline to learn *which* job failed and why. On the
# infra-bail path (PipelineMonitor#infra_skip?) that information is already in
# memory (the failing job names + their GitLab `failure_reason`), so we now
# persist a concise human string like `deploy_review (script_failure)` here and
# surface it in the stagnation notification, the activity log, and the dashboard
# watch card. Kept separate from `attention_reason` so callers that key off the
# reason (e.g. auto-retry) are unaffected. Cleared on reentry / manual reset like
# the sibling attention columns.
#
# `if_not_exists`-aware so it's a no-op on a DB that already has the column.
class AddAttentionDetailToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :attention_detail, :text, if_not_exists: true
  end

  def down
    remove_column :issues, :attention_detail, if_exists: true
  end
end
