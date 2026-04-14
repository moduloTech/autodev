# frozen_string_literal: true

# AASM state machine and guard methods for the Issue model.
# Extracted from Database.build_model! to keep method sizes manageable.
#
# The state machine is split across focused modules under IssueBehavior::Events,
# each registered via separate `aasm` calls (AASM merges them into one machine).
module IssueBehavior
  def self.included(klass)
    klass.include(AASM)
    klass.attr_writer :_issue_closed, :_skip_to_mr,
                      :_unresolved_discussions_empty, :_post_completion,
                      :_review_count_zero, :_review_count_over_zero, :_max_review_rounds_reached
    klass.include(States)
    klass.include(HappyPathEvents)
    klass.include(PipelineEvents)
    klass.include(FixAndResumeEvents)
    klass.include(ErrorEvents)
  end

  # -- Guard methods --

  def issue_closed?
    @_issue_closed == true
  end

  def skip_to_mr?
    @_skip_to_mr == true
  end

  def no_unresolved_discussions?
    @_unresolved_discussions_empty == true
  end

  def post_completion?
    @_post_completion == true
  end

  def review_count_zero?
    @_review_count_zero == true
  end

  def review_count_over_zero?
    @_review_count_over_zero == true
  end

  def max_review_rounds_reached?
    @_max_review_rounds_reached == true
  end

  # -- Persistence callback --

  def persist_status_change!
    save_changes
  end

  # State definitions and global after_all_transitions callback.
  module States
    def self.included(klass)
      klass.aasm column: :status, whiny_transitions: false do
        state :pending, initial: true
        state :cloning, :checking_spec, :implementing, :committing, :pushing
        state :creating_mr, :reviewing, :checking_pipeline
        state :fixing_discussions, :fixing_pipeline, :running_post_completion
        state :answering_question, :needs_clarification
        state :done, :error

        after_all_transitions :persist_status_change!
      end
    end
  end

  # Happy path: issue -> spec check -> implement -> MR -> checking_pipeline
  module HappyPathEvents
    def self.included(klass)
      define_initial_events(klass)
      define_clone_complete_event(klass)
      define_implementation_events(klass)
    end

    def self.define_initial_events(klass)
      klass.aasm do
        event(:start_processing) { transitions from: :pending, to: :cloning }
        event(:spec_clear) { transitions from: :checking_spec, to: :implementing }
        event(:spec_unclear) { transitions from: :checking_spec, to: :needs_clarification }
        event(:question_detected) { transitions from: :checking_spec, to: :answering_question }
        event(:question_answered) { transitions from: :answering_question, to: :done }
      end
    end

    def self.define_clone_complete_event(klass)
      klass.aasm do
        event :clone_complete do
          transitions from: :cloning, to: :done, guard: :issue_closed?
          transitions from: :cloning, to: :creating_mr, guard: :skip_to_mr?
          transitions from: :cloning, to: :checking_spec
        end
      end
    end

    def self.define_implementation_events(klass)
      klass.aasm do
        event(:impl_complete) { transitions from: :implementing, to: :committing }
        event(:commit_complete) { transitions from: :committing, to: :pushing }
        event(:push_complete) { transitions from: :pushing, to: :creating_mr }
        event(:mr_created) { transitions from: :creating_mr, to: :checking_pipeline }
      end
    end

    private_class_method :define_initial_events, :define_clone_complete_event,
                         :define_implementation_events
  end

  # Pipeline monitoring events.
  module PipelineEvents
    def self.included(klass)
      define_pipeline_green_event(klass)
      define_pipeline_outcome_events(klass)
    end

    def self.define_pipeline_green_event(klass)
      klass.aasm do
        event :pipeline_green do
          transitions from: :checking_pipeline, to: :done, guard: :max_review_rounds_reached?
          transitions from: :checking_pipeline, to: :reviewing, guard: :review_count_zero?
          transitions from: :checking_pipeline, to: :done,
                      guard: %i[review_count_over_zero? no_unresolved_discussions?]
          transitions from: :checking_pipeline, to: :fixing_discussions, guard: :review_count_over_zero?
        end
      end
    end

    def self.define_pipeline_outcome_events(klass)
      klass.aasm do
        event(:post_completion_done) { transitions from: :running_post_completion, to: :done }
        event(:start_post_completion) { transitions from: :done, to: :running_post_completion }
        event(:review_done) { transitions from: :reviewing, to: :checking_pipeline }
        event(:pipeline_failed_code) { transitions from: :checking_pipeline, to: :fixing_pipeline }
        event(:mr_closed) { transitions from: :checking_pipeline, to: :done }
      end
    end

    private_class_method :define_pipeline_green_event, :define_pipeline_outcome_events
  end

  # Fix cycles, clarification, and reentry events.
  module FixAndResumeEvents
    def self.included(klass)
      klass.aasm do
        event(:discussions_fixed) { transitions from: :fixing_discussions, to: :checking_pipeline }
        event(:pipeline_fix_done) { transitions from: :fixing_pipeline, to: :checking_pipeline }
        event(:clarification_received) { transitions from: :needs_clarification, to: :pending }
        event(:reenter) { transitions from: :done, to: :pending }
      end
    end
  end

  # Error handling events.
  module ErrorEvents
    def self.included(klass)
      klass.aasm do
        event :mark_failed do
          transitions from: %i[cloning checking_spec implementing committing
                               pushing creating_mr reviewing
                               fixing_discussions fixing_pipeline
                               running_post_completion answering_question], to: :error
        end

        event(:retry_processing) { transitions from: :error, to: :pending }
        event(:retry_pipeline) { transitions from: :error, to: :checking_pipeline }
      end
    end
  end
end
