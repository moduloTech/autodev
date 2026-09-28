# frozen_string_literal: true

module Autodev
  class LabelHandover
    # Stage 3 of `LabelHandover#verdict` (Autodev #101), kept apart from the two
    # stages that read the current labels because it reads something else: the
    # resource label events, over a window the row's own clocks bound.
    #
    # It relies on the includer's definitions, never on copies of them —
    # `by_someone_else?`, `label_name`, `scope`, `scope_of`, `configured_labels`,
    # the four configured labels and `events` — so "someone else", "in my scope"
    # and "the ticket's history" mean exactly what they mean in stages 1 and 2.
    module ErasedScan
      private

      # Stage 3 (Autodev #101) — the handover a label write of autodev's erased.
      #
      # The current labels are destructible evidence: autodev's own writes remove
      # values (`other_workflow_labels` lists `label_done` when `label_doing` is
      # posed), and once the value is gone `suspect` has nothing to find. The
      # events are not destructible. Reading them on every verdict would cost one
      # call per page per active row per cycle — about 6 500 requests a day at the
      # 7 active rows of 28/09/2026, against 8 300 in all — so they are read only
      # when an autodev write has happened since they were last read, which is the
      # one way the evidence disappears: at most one read per autodev label write.
      #
      # Nil when nothing was erased, or when the scan is not due. A scan that finds
      # nothing advances the floor to the moment *before* the read, so a write
      # landing during the read is still after the floor and fires the next cycle.
      def erased_handover(issue_iid, row)
        clocks = row && label_clocks(row)
        return unless clocks && scan_due?(clocks)

        floor = clocks.values_at(:seen_until, :started_at, :created_at).compact.max
        found = erased_evidence(window(events(issue_iid), floor))
        advance_floor(row, @read_started_at.fetch(issue_iid)) unless found
        found
      end

      # Re-read rather than taken off `row`: the stamp is an `update_all`, which no
      # in-memory row sees. Only a persisted `Issue` has clocks; anything else
      # (a row not yet saved, a caller's stand-in) gets stages 1 and 2 alone.
      def label_clocks(row)
        return unless row.is_a?(::Issue) && row.persisted?

        values = ::Issue.where(id: row.id)
                        .pick(:labels_written_at, :label_events_seen_until, :started_at, :created_at)
        values && %i[written_at seen_until started_at created_at].zip(values).to_h
      end

      # Strictly after: the floor is taken before the read, so a write that
      # landed during or after it is later than the floor, and one stamped at the
      # floor itself preceded the read. A NULL floor — a row created after the
      # migration's backfill that has never been scanned — is due at its first
      # write.
      def scan_due?(clocks)
        written = clocks[:written_at]
        return false unless written

        clocks[:seen_until].nil? || written > clocks[:seen_until]
      end

      # Only moved forward: two passes reading the same row must not pull it back.
      def advance_floor(row, read_at)
        ::Issue.where(id: row.id)
               .where('label_events_seen_until IS NULL OR label_events_seen_until < ?', read_at)
               .update_all(label_events_seen_until: read_at)
      end

      # The window starts at the latest of the floor, the current claim
      # (`started_at`, stamped by `IssueProcessor#start_processing`; NULL after a
      # reset to `checking_pipeline`, hence `compact`) and the row's own birth.
      # An event with no readable `created_at` is never evidence.
      def window(all, floor)
        all.select do |event|
          at = event_time(event)
          at && (floor.nil? || at > floor)
        end
      end

      # Same order as `suspect`, for the same reason: the most informative first.
      # Autodev's own events are left out on purpose — autodev removing the value
      # afterwards is exactly the erasure, it does not undo the human's act. The
      # same human removing it again does.
      def erased_evidence(events)
        theirs = events.select { |event| by_someone_else?(event) }
        erased_done(theirs) || erased_move(theirs) || erased_doing(theirs)
      end

      def erased_done(theirs)
        Verdict.new(:done_added, label_done) if label_done && standing_add?(theirs, label_done)
      end

      # The newest foreign value in autodev's scope whose add still stands.
      def erased_move(theirs)
        return unless scope

        theirs.reverse_each do |event|
          name = label_name(event)
          next unless name && scope_of(name) == scope && !configured_labels.include?(name)

          return Verdict.new(:workflow_moved, name) if standing_add?(theirs, name)
        end
        nil
      end

      # `doing_dropped?`'s rule over the history: a todo label posed by somebody
      # else anywhere in the window explains the absence — the "repose the todo
      # label and reassign me" gesture, whether it came as one edit or two.
      def erased_doing(theirs)
        return unless label_doing

        last = theirs.select { |event| label_name(event) == label_doing }.last
        return unless last && action(last) == 'remove'
        return if todo_posed?(theirs)

        Verdict.new(:doing_removed, label_doing)
      end

      def todo_posed?(theirs)
        theirs.any? { |event| action(event) == 'add' && labels_todo.include?(label_name(event)) }
      end

      # The last edit somebody else made on `name` is an add, and nobody but
      # autodev asked for work again since: a todo label or `label_doing` posed by
      # somebody else at or after it (a board move writes one event per label, all
      # with the same timestamp) means the ticket was handed back, not taken.
      def standing_add?(theirs, name)
        last = theirs.select { |event| label_name(event) == name }.last
        return false unless last && action(last) == 'add'

        at = event_time(last)
        theirs.none? { |event| asked_for_work?(event) && event_time(event) >= at }
      end

      def asked_for_work?(event)
        action(event) == 'add' && (labels_todo + [label_doing]).compact.include?(label_name(event))
      end

      def action(event) = ::GitlabHelpers.field(event, :action).to_s

      def event_time(event)
        at = ::GitlabHelpers.field(event, :created_at)
        at && (at.is_a?(Time) ? at : Time.parse(at.to_s))
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
