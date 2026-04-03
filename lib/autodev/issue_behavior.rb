# frozen_string_literal: true

# AASM state machine and guard methods for the Issue model.
# Extracted from Database.build_model! to keep method sizes manageable.
#
# The state machine is split across focused modules under IssueBehavior::Events,
# each registered via separate `aasm` calls (AASM merges them into one machine).
module IssueBehavior
  def self.included(klass)
    klass.include(AASM)
    klass.attr_writer :_issue_closed, :_skip_to_mr, :_max_fix_rounds,
                      :_unresolved_discussions_empty, :_post_completion
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

  def max_fix_rounds_reached?
    fix_round >= (@_max_fix_rounds || 3)
  end

  def can_fix?
    fix_round < (@_max_fix_rounds || 3)
  end

  def post_completion?
    @_post_completion == true
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
        state :over, :blocked, :error

        after_all_transitions :persist_status_change!
      end
    end
  end

  # Happy path: issue -> spec check -> implement -> MR
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
        event(:question_answered) { transitions from: :answering_question, to: :over }
      end
    end

    def self.define_clone_complete_event(klass)
      klass.aasm do
        event :clone_complete do
          transitions from: :cloning, to: :over, guard: :issue_closed?
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
        event(:mr_created) { transitions from: :creating_mr, to: :reviewing }
        event(:review_complete) { transitions from: :reviewing, to: :checking_pipeline }
      end
    end

    private_class_method :define_initial_events, :define_clone_complete_event,
                         :define_implementation_events
  end

  # Pipeline monitoring events.
  module PipelineEvents
    GREEN_POST_COMPLETION_GUARD = %i[no_unresolved_discussions? post_completion?].freeze
    GREEN_MAX_ROUNDS_GUARD = %i[max_fix_rounds_reached? post_completion?].freeze

    def self.included(klass)
      define_pipeline_green_event(klass)
      define_pipeline_outcome_events(klass)
    end

    def self.define_pipeline_green_event(klass)
      klass.aasm do
        event :pipeline_green do
          transitions from: :checking_pipeline, to: :running_post_completion, guard: GREEN_POST_COMPLETION_GUARD
          transitions from: :checking_pipeline, to: :over, guard: :no_unresolved_discussions?
          transitions from: :checking_pipeline, to: :running_post_completion, guard: GREEN_MAX_ROUNDS_GUARD
          transitions from: :checking_pipeline, to: :over, guard: :max_fix_rounds_reached?
          transitions from: :checking_pipeline, to: :fixing_discussions
        end
      end
    end

    def self.define_pipeline_outcome_events(klass)
      klass.aasm do
        event(:post_completion_done) { transitions from: :running_post_completion, to: :over }

        event :pipeline_failed_code do
          transitions from: :checking_pipeline, to: :fixing_pipeline, guard: :can_fix?
          transitions from: :checking_pipeline, to: :blocked
        end

        event(:pipeline_failed_infra) { transitions from: :checking_pipeline, to: :blocked }
        event(:pipeline_canceled) { transitions from: :checking_pipeline, to: :blocked }
      end
    end

    private_class_method :define_pipeline_green_event, :define_pipeline_outcome_events
  end

  # Fix cycles, clarification, and resume events.
  module FixAndResumeEvents
    def self.included(klass)
      klass.aasm do
        event(:discussions_fixed) { transitions from: :fixing_discussions, to: :checking_pipeline }
        event(:pipeline_fix_done) { transitions from: :fixing_pipeline, to: :checking_pipeline }
        event(:clarification_received) { transitions from: :needs_clarification, to: :pending }
        event(:resume_todo) { transitions from: :over, to: :pending }
        event(:resume_mr) { transitions from: :over, to: :fixing_discussions }
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
