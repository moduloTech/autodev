# frozen_string_literal: true

module Web
  module Views
    # Standalone sign-in landing — rendered to anonymous traffic by
    # SignInController, kicked off by `EntraIdFailureApp.redirect_url`
    # whenever `authenticate_user!` fails. Deliberately doesn't go
    # through Web::Views::Layout: the layout opens a `/stream`
    # EventSource which is gated and would redirect-loop in the
    # browser console. This page is a self-contained HTML document.
    class SignIn < Base
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

      def view_template # rubocop:disable Metrics/MethodLength
        doctype
        html(lang: @locale.to_s) do
          render_head
          body do
            div(style: 'min-height: 100vh; display: flex; align-items: center; ' \
                       'justify-content: center; padding: 24px;') do
              div(style: 'max-width: 360px; text-align: center;') do
                h1(style: 'margin: 0 0 8px 0; font-size: 28px;') { plain 'autodev' }
                p(class: 'muted', style: 'margin: 0 0 32px 0;') { t_web(:web_sign_in_subtitle) }
                form(method: 'post', action: '/users/auth/entra_id') do
                  csrf_input_tag
                  button(type: 'submit', style: BUTTON_STYLE) { t_web(:web_sign_in_button) }
                end
              end
            end
          end
        end
      end

      private

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
