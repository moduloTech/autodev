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
    #
    # Generalized (task #43) so the same component also renders the "deploy a
    # review env for an off-autodev MR" surface (`/deploy_review`), where
    # there's no issue row/id — just an arbitrary (project, mr_iid) pair.
    # `issue_id:` remains the convenient default: passing it alone reproduces
    # the original ticket-page behavior (frame_id/src/submit_action derived
    # from it). The MR surface instead passes `frame_id:` + `src:` (its GET
    # probe is a query-string endpoint, not a `/:id` path segment) + optional
    # `hidden_fields:` — extra hidden inputs the trigger form needs to carry
    # (project/mr_iid) since they aren't part of the POST URL.
    class DeployReviewFrame < Base
      register_element :turbo_frame

      # Deterministic frame id for the MR surface — shared by the index page's
      # embedded `:loading` frame and the availability probe's resolved
      # response, so Turbo can match them up.
      def self.mr_frame_id(project_path, mr_iid)
        "deploy-review-mr-#{project_path.to_s.tr('/', '-')}-#{mr_iid}"
      end

      def initialize( # rubocop:disable Metrics/ParameterLists
        state:, action: nil, issue_id: nil,
        frame_id: nil, src: nil, submit_action: nil, hidden_fields: {}, **
      )
        @state = state
        @action = action
        @frame_id = frame_id || "deploy-review-#{issue_id}"
        @src = src || "/issues/#{issue_id}/deploy_review"
        @submit_action = submit_action || @src
        @hidden_fields = hidden_fields
        super(**)
      end

      # `src` + `loading="lazy"` belong ONLY on the frame the issue page
      # embeds (state :loading): they tell Turbo to lazily fetch the resolved
      # frame. The lazy-fetch *response* (every other state) must NOT re-emit
      # them — Turbo 8 treats a response `<turbo-frame>` that still carries
      # `src`/`loading="lazy"` as a fresh lazy frame, blanks it and re-navigates,
      # so the button flashed in and then vanished (Autodev #28). The resolved
      # frame therefore ships as a bare `<turbo-frame id>` + content.
      def view_template
        attrs = { id: frame_id }
        attrs.merge!(src: src, loading: 'lazy') if @state == :loading
        turbo_frame(**attrs) do
          case @state
          when :loading   then render_placeholder
          when :available then render_button
          else                 render_unavailable
          end
        end
      end

      private

      attr_reader :frame_id, :src

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
        form(method: 'post', action: @submit_action, 'data-turbo-frame' => '_top',
             data: { confirm: t_web(:web_issue_confirm_deploy_review) }) do
          csrf_input_tag
          render_hidden_fields
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

      # Extra hidden inputs the trigger form needs alongside the CSRF token —
      # empty for the ticket surface (issue id is already in the POST URL),
      # `{ project:, mr_iid: }` for the MR surface (query-string params, not
      # path segments, so they must ride along as form fields).
      def render_hidden_fields
        # `name.to_s` matters: Phlex dasherizes bare Symbol attribute VALUES
        # (same rule that turns `stroke_width: '1.6'` into `stroke-width`
        # elsewhere) — passing the Symbol straight through would rewrite
        # `:mr_iid` into the literal string "mr-iid" and break the param name.
        @hidden_fields.each { |name, value| input(type: 'hidden', name: name.to_s, value: value) }
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
