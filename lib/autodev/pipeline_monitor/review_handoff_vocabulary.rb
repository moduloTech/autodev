# frozen_string_literal: true

class PipelineMonitor
  # What `ReviewHandoff` and its two halves share (Autodev #90): the label
  # vocabulary of the author-side skill's materializer, the values the
  # handoff passes between its steps, and the words its entries are made of.
  # A module of its own so each half reaches them through its ancestors.
  module ReviewHandoffVocabulary
    SIZE_CLASSES = %w[XS S M L XL XXL].freeze
    # `MrMaterialize::LabelPlan`'s table: the analyzer says `medium`, the label
    # reads `Standard`. An unknown zone is a failed measurement, never a label —
    # GitLab creates any label it is handed.
    COVERAGE_ZONE_LABELS = { 'high' => 'High', 'medium' => 'Standard', 'low' => 'Low', 'red' => 'Red' }.freeze
    SIZE_PREFIX = 'MR::Size::'
    COVERAGE_PREFIX = 'MR::TestCoverage::'
    REVIEWER_PREFIX = 'MR::Reviewer::'
    READY_LABEL = 'MR::ReadyForReview'
    # `reviewer_draw`'s "no draw made": the People absence check could not run.
    DRAW_UNAVAILABLE_EXIT = 2

    # Every activity entry the handoff can write (`activity_<key>`). The keys
    # travel through `Stop` and `ready_entry`, so the i18n scan cannot read
    # them at the call site: this list is the family it checks instead, and
    # `test/an_autodev_mr_reaches_its_reviewer_test.rb` derives it from the code.
    OUTCOMES = %i[review_handoff_ready review_handoff_ready_reviewer_kept review_handoff_ready_no_draw
                  review_handoff_no_reviewer_absences review_handoff_no_reviewer_postponed
                  review_handoff_no_reviewer_draw_failed review_handoff_no_reviewer_unresolved
                  review_handoff_not_measured review_handoff_not_landed review_handoff_not_confirmed
                  review_handoff_ready_not_confirmed review_handoff_failed].freeze

    # Ends the handoff with one activity entry.
    class Stop < StandardError
      attr_reader :key, :vars

      def initialize(key, **vars)
        super(key.to_s)
        @key = key
        @vars = vars
      end
    end

    # A drawn developer, resolved: GitLab id and the label humans write.
    DrawnReviewer = Struct.new(:username, :id, :label)
    # What the scripts measured. `draw` is one of `:kept`, `:not_declared`, an
    # Array of `DrawnReviewer` (reviewer first, assignee second), or a `Stop`.
    Measurement = Struct.new(:size_class, :zone, :draw)

    private

    # The words the entries are assembled from, in the issue's language: they
    # land in a published note like the rest of it (phase-10 review of the
    # alpha-57 lot — "reviewer <user>" sat in English inside French notes).
    def added_labels(issue, added)
      return added.join(', ') if added.any?

      Locales.t(:activity_review_handoff_part_no_label, locale: handoff_locale(issue))
    end

    def ready_status(issue, current)
      locale = handoff_locale(issue)
      return Locales.t(:activity_review_handoff_part_ready_left, locale: locale) if current.include?(READY_LABEL)

      Locales.t(:activity_review_handoff_part_ready_not_posted, locale: locale)
    end

    # What a stopped handoff says of Ready, by the labels the merge request
    # carried when the handoff read it: `post_ready` leaves one already there,
    # so "not posted" alone read as "absent" (phase-10 review of the alpha-57
    # lot). A merge request never read is one Ready was certainly not posted on.
    def handoff_ready_status(issue) = ready_status(issue, @handoff_labels_before.to_a)

    def reviewer_claim(issue, user)
      Locales.t(:activity_review_handoff_part_reviewer, locale: handoff_locale(issue), username: user.username)
    end

    def assignee_claim(issue, user)
      Locales.t(:activity_review_handoff_part_assignee, locale: handoff_locale(issue), username: user.username)
    end

    def handoff_locale(issue) = (issue.locale || 'fr').to_sym
  end
end
