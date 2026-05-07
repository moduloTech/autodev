# frozen_string_literal: true

module Web
  module Views
    module Components
      # Pill that translates an AASM state into a localized label with a
      # colored dot. Mirrors design_handoff_autodev/primitives.jsx StatusPill.
      #
      # Tones (working / ok / warn / err / neutral) come from the design
      # tokens; the dot pulses for `working` to convey live activity.
      class StatusPill < Phlex::HTML
        # AASM state → { label_key (i18n), tone (color family) }.
        # Source of truth: primitives.jsx::STATUS.
        STATUS_DATA = {
          'pending' => { label_key: :web_status_pending,                 tone: :neutral },
          'cloning' => { label_key: :web_status_cloning,                 tone: :working },
          'checking_spec' => { label_key: :web_status_checking_spec,           tone: :working },
          'needs_clarification' => { label_key: :web_status_needs_clarification,     tone: :warn },
          'implementing' => { label_key: :web_status_implementing, tone: :working },
          'committing' => { label_key: :web_status_committing, tone: :working },
          'pushing' => { label_key: :web_status_pushing, tone: :working },
          'creating_mr' => { label_key: :web_status_creating_mr, tone: :working },
          'reviewing' => { label_key: :web_status_reviewing, tone: :working },
          'checking_pipeline' => { label_key: :web_status_checking_pipeline, tone: :working },
          'fixing_discussions' => { label_key: :web_status_fixing_discussions, tone: :working },
          'fixing_pipeline' => { label_key: :web_status_fixing_pipeline, tone: :working },
          'running_post_completion' => { label_key: :web_status_running_post_completion, tone: :working },
          'answering_question' => { label_key: :web_status_answering_question, tone: :working },
          'done' => { label_key: :web_status_done, tone: :ok },
          'error' => { label_key: :web_status_error, tone: :err }
        }.freeze

        TONE_VARS = {
          neutral: { bg: 'var(--paper-2)', fg: 'var(--text-muted)', dot: 'var(--text-subtle)' },
          working: { bg: 'var(--work-bg)', fg: 'var(--work-fg)',    dot: 'var(--work-500)' },
          ok: { bg: 'var(--ok-bg)', fg: 'var(--ok-fg)', dot: 'var(--ok-500)' },
          warn: { bg: 'var(--warn-bg)', fg: 'var(--warn-fg)', dot: 'var(--warn-500)' },
          err: { bg: 'var(--err-bg)', fg: 'var(--err-fg)', dot: 'var(--err-500)' }
        }.freeze

        SIZES = {
          sm: { padding: '2px 8px',  font_size: 11, gap: 5, dot: 5 },
          md: { padding: '3px 10px', font_size: 12, gap: 6, dot: 6 },
          lg: { padding: '5px 12px', font_size: 13, gap: 7, dot: 7 }
        }.freeze

        def initialize(status:, label:, size: :md, with_dot: true) # rubocop:disable Lint/MissingSuper
          @status = status.to_s
          @label = label
          @size = SIZES[size] || SIZES[:md]
          @with_dot = with_dot
          @data = STATUS_DATA[@status] || { label_key: nil, tone: :neutral }
          @tone = TONE_VARS[@data[:tone]]
        end

        def view_template
          span(class: 'pill', style: pill_style) do
            span(class: dot_classes, style: dot_style) if @with_dot
            plain @label
          end
        end

        private

        def pill_style
          "display: inline-flex; align-items: center; gap: #{@size[:gap]}px; " \
            "padding: #{@size[:padding]}; font-size: #{@size[:font_size]}px; " \
            'font-weight: 500; line-height: 1.4; white-space: nowrap; ' \
            "background: #{@tone[:bg]}; color: #{@tone[:fg]}; " \
            'border-radius: var(--r-pill);'
        end

        def dot_classes
          @data[:tone] == :working ? 'pill-dot pill-dot-pulse' : 'pill-dot'
        end

        def dot_style
          "width: #{@size[:dot]}px; height: #{@size[:dot]}px; " \
            "background: #{@tone[:dot]}; border-radius: 50%; flex: 0 0 auto;"
        end
      end
    end
  end
end
