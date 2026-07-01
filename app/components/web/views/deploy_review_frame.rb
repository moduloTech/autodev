# frozen_string_literal: true

module Web
  module Views
    # Lazy-loaded `<turbo-frame>` holding the "redeploy review env" action.
    #
    # The issue page renders this with `state: :loading` and a `src` pointing
    # at `GET /issues/:id/deploy_review`; Turbo fetches that endpoint after the
    # page paints (so the GitLab round-trip never blocks the issue view) and
    # swaps in the resolved frame — an enabled button when an actionable
    # `deploy_review` job exists on the relevant pipeline, or a disabled button
    # plus a one-line reason (from Autodev::DeployReview.reason_key) when it
    # doesn't.
    #
    # The trigger form targets `_top`: a successful POST redirects the whole
    # page to the issue, surfacing the global flash banner (the frame alone
    # can't repaint the banner that lives outside it).
    class DeployReviewFrame < Base
      register_element :turbo_frame

      def initialize(issue_id:, state:, action: nil, **)
        @issue_id = issue_id
        @state = state
        @action = action
        super(**)
      end

      def view_template
        turbo_frame(id: frame_id, src: src, loading: 'lazy') do
          case @state
          when :loading   then render_placeholder
          when :available then render_button
          else                 render_unavailable
          end
        end
      end

      private

      def frame_id
        "deploy-review-#{@issue_id}"
      end

      def src
        "/issues/#{@issue_id}/deploy_review"
      end

      def render_placeholder
        render Components::Button.new(kind: :secondary, size: :md, full: true, disabled: true,
                                      icon: Components::Icon.new(name: 'rocket', size: 13)) do
          t_web(:web_issue_deploy_review)
        end
      end

      # :play → first deploy ("Déployer"), :retry → redeploy ("Redéployer").
      def button_label_key
        @action == :play ? :web_issue_deploy_review_play : :web_issue_deploy_review
      end

      def render_button
        form(method: 'post', action: src, 'data-turbo-frame' => '_top',
             data: { confirm: t_web(:web_issue_confirm_deploy_review) }) do
          csrf_input_tag
          # data-turbo-submits-with disables the button and swaps its label for
          # the duration of the (Turbo-driven) submission — a proportionate,
          # confirm-safe guard against an accidental double-click re-triggering
          # the job. It only fires once the confirm dialog is accepted, so a
          # cancelled dialog never leaves the button stuck. (Decision: task #18 —
          # no server-side lock, this is the sole defense-in-depth kept.)
          render Components::Button.new(kind: :secondary, size: :md, full: true, type: 'submit',
                                        data: { turbo_submits_with: t_web(:web_issue_deploy_review_submitting) },
                                        icon: Components::Icon.new(name: 'rocket', size: 13)) do
            t_web(button_label_key)
          end
        end
      end

      def render_unavailable
        render Components::Button.new(kind: :secondary, size: :md, full: true, disabled: true,
                                      icon: Components::Icon.new(name: 'rocket', size: 13)) do
          t_web(:web_issue_deploy_review)
        end
        p(class: 'muted', style: 'font-size: 12px; margin: 6px 0 0;') do
          t_web(Autodev::DeployReview.reason_key(@state))
        end
      end
    end
  end
end
