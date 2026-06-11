# frozen_string_literal: true

module Web
  module Views
    # Standalone sign-in landing — rendered to anonymous traffic by
    # SignInController, kicked off by `EntraIdFailureApp.redirect_url`
    # whenever `authenticate_user!` fails. Deliberately doesn't go
    # through Web::Views::Layout: the layout opens a `/stream`
    # EventSource which is gated and would redirect-loop in the
    # browser console. This page is a self-contained HTML document.
    class SignIn < Base # rubocop:disable Metrics/ClassLength
      BUTTON_STYLE = <<~CSS.gsub(/\s+/, ' ').strip
        background: var(--accent-solid);
        color: white;
        border: 0;
        padding: 14px 28px;
        border-radius: var(--r-md);
        cursor: pointer;
        font-size: 15px;
        font-weight: 500;
      CSS
      private_constant :BUTTON_STYLE

      def view_template
        doctype
        html(lang: @locale.to_s) do
          render_head
          body { render_body }
        end
      end

      private

      WRAPPER_STYLE = 'min-height: 100vh; display: flex; align-items: center; ' \
                      'justify-content: center; padding: 24px;'
      INNER_STYLE = 'max-width: 480px; text-align: center;'
      private_constant :WRAPPER_STYLE, :INNER_STYLE

      def render_body
        div(style: WRAPPER_STYLE) do
          div(style: INNER_STYLE) do
            h1(style: 'margin: 0 0 8px 0; font-size: 28px;') { plain 'autodev' }
            p(class: 'muted', style: 'margin: 0 0 32px 0;') { t_web(:web_sign_in_subtitle) }
            render_dev_setup_banner if dev_with_stub_credentials?
            render_dev_empty_projects_banner if dev_with_empty_projects?
            render_signin_form
          end
        end
      end

      def render_signin_form
        form(method: 'post', action: '/users/auth/entra_id') do
          csrf_input_tag
          button(type: 'submit', style: BUTTON_STYLE) { t_web(:web_sign_in_button) }
        end
      end

      # In dev, surface a clear banner when Azure SSO creds are still set
      # to the stub fallback — clicking the button would just bounce off
      # Microsoft with AADSTS700016, which is hard to diagnose from the
      # consent-screen error alone.
      def dev_with_stub_credentials?
        Rails.env.development? && Config.azure_stub_credentials?(::Web.config)
      end

      # Same idea, second well-known dev-only failure: the `projects`
      # table is empty so `GitlabMembershipSync` will compute zero
      # memberships, mark the user `disabled`, and Devise refuses the
      # sign-in with 401. The fix is `bin/rails autodev:migrate_projects_from_yaml`.
      def dev_with_empty_projects?
        Rails.env.development? && !Project.exists?
      end

      BANNER_STYLE = <<~CSS.gsub(/\s+/, ' ').strip
        background: var(--err-bg);
        color: var(--err-fg);
        border: 1px solid var(--err-200);
        border-radius: var(--r-md);
        padding: 14px 16px;
        margin: 0 0 24px 0;
        text-align: left;
        font-size: 13px;
        line-height: 1.5;
      CSS
      CODE_STYLE = 'background: var(--paper-2); padding: 1px 6px; border-radius: var(--r-xs); ' \
                   'font-family: var(--font-mono); font-size: 12px; color: var(--text);'
      private_constant :BANNER_STYLE, :CODE_STYLE

      def render_dev_setup_banner
        div(style: BANNER_STYLE) do
          div(style: 'font-weight: 600; margin-bottom: 6px;') { t_web(:web_sign_in_dev_banner_title) }
          p(style: 'margin: 0 0 8px 0;') { t_web(:web_sign_in_dev_banner_body) }
          ul(style: 'margin: 0; padding-left: 18px;') do
            li { render_dev_step_yaml }
            li { render_dev_step_env }
            li { render_dev_step_redirect }
          end
        end
      end

      def render_dev_step_yaml
        plain t_web(:web_sign_in_dev_step_yaml_prefix)
        plain ' '
        code(style: CODE_STYLE) { '~/.autodev/config.yml' }
        plain ' '
        plain t_web(:web_sign_in_dev_step_yaml_suffix)
        plain ' '
        code(style: CODE_STYLE) { 'azure: { client_id, client_secret, tenant_id }' }
      end

      def render_dev_step_env
        plain t_web(:web_sign_in_dev_step_env_prefix)
        plain ' '
        code(style: CODE_STYLE) { 'AZURE_AD_CLIENT_ID / AZURE_AD_CLIENT_SECRET / AZURE_AD_TENANT_ID' }
      end

      def render_dev_empty_projects_banner
        div(style: BANNER_STYLE) do
          div(style: 'font-weight: 600; margin-bottom: 6px;') { t_web(:web_sign_in_dev_empty_projects_title) }
          p(style: 'margin: 0 0 8px 0;') { t_web(:web_sign_in_dev_empty_projects_body) }
          p(style: 'margin: 0;') { render_empty_projects_fix }
        end
      end

      def render_empty_projects_fix
        plain t_web(:web_sign_in_dev_empty_projects_fix_prefix)
        plain ' '
        code(style: CODE_STYLE) { 'bin/rails autodev:migrate_projects_from_yaml' }
      end

      def render_dev_step_redirect
        plain t_web(:web_sign_in_dev_step_redirect_prefix)
        plain ' '
        code(style: CODE_STYLE) { 'http://localhost:4567/users/auth/entra_id/callback' }
        plain ' '
        plain t_web(:web_sign_in_dev_step_redirect_suffix)
      end

      def render_head
        head do
          meta(charset: 'utf-8')
          meta(name: 'viewport', content: 'width=device-width, initial-scale=1')
          title { t_web(:web_sign_in_title) }
          link(rel: 'stylesheet', href: '/assets/css/tokens.css')
          link(rel: 'stylesheet', href: '/assets/css/fonts.css')
          link(rel: 'stylesheet', href: '/assets/css/app.css')
        end
      end
    end
  end
end
