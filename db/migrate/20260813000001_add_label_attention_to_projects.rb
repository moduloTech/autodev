# frozen_string_literal: true

# The label a give-up poses instead of `label_done` (Autodev #63).
#
# Every abandon path used to call `apply_label_done`, and on powerpanne/core
# `label_done` is `Development::Awaiting Feature Review` — so a ticket autodev
# gave up on arrived on the review board announced as reviewed. 28 of them did
# during the 11/08/2026 incident.
#
# Nullable and optional: the scope autodev derives from `label_doing` +
# `label_done` names a scope, not its values, and the real projects' third values
# (`Development::StandBy`, `Awaiting CR`, `Awaiting Merge` on powerpanne;
# `NeedEstimation` alone on ff/fast/core) are project taxonomy autodev cannot
# pick from. Unset is a defined fallback — no end label, the row keeps
# `label_doing` — not a missing setting.
class AddLabelAttentionToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :label_attention, :string, if_not_exists: true
  end
end
