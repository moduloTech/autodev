# frozen_string_literal: true

module Web
  module Views
    module Components
      # Themed button. Mirrors primitives.jsx::Button: kinds primary/
      # secondary/ghost/danger/dangerSolid/okSolid, sizes sm/md/lg.
      # Optional leading and trailing icons, full-width opt-in.
      class Button < Phlex::HTML
        SIZES = {
          sm: { padding: '5px 10px',  font_size: 12, gap: 6,  radius: 'var(--r-sm)' },
          md: { padding: '8px 14px',  font_size: 13, gap: 8,  radius: 'var(--r-md)' },
          lg: { padding: '11px 18px', font_size: 14, gap: 10, radius: 'var(--r-md)' }
        }.freeze

        VARIANTS = {
          primary: 'background: var(--accent-solid); color: var(--text-on-accent); ' \
                   'border: 1px solid var(--accent-solid-hover); ' \
                   'box-shadow: 0 1px 0 rgba(0,0,0,0.06), inset 0 1px 0 rgba(255,255,255,0.12);',
          secondary: 'background: var(--paper); color: var(--text); ' \
                     'border: 1px solid var(--border); box-shadow: var(--shadow-xs);',
          ghost: 'background: transparent; color: var(--text-muted); ' \
                 'border: 1px solid transparent;',
          danger: 'background: var(--paper); color: var(--err-fg); ' \
                  'border: 1px solid var(--err-200);',
          danger_solid: 'background: var(--err-500); color: white; ' \
                        'border: 1px solid var(--err-700);',
          ok_solid: 'background: var(--ok-500); color: white; ' \
                    'border: 1px solid var(--ok-700);'
        }.freeze

        # rubocop:disable Metrics/ParameterLists
        def initialize( # rubocop:disable Lint/MissingSuper
          kind: :secondary, size: :md, type: 'button',
          icon: nil, icon_right: nil, full: false, disabled: false,
          href: nil, extra_style: nil
        )
          @kind = kind
          @size = SIZES[size] || SIZES[:md]
          @variant = VARIANTS[kind] || VARIANTS[:secondary]
          @type = type
          @icon = icon
          @icon_right = icon_right
          @full = full
          @disabled = disabled
          @href = href
          @extra_style = extra_style
        end
        # rubocop:enable Metrics/ParameterLists

        def view_template(&)
          if @href
            a(href: @href, class: 'btn', style: full_style) { render_inner(&) }
          else
            button(type: @type, disabled: @disabled, class: 'btn', style: full_style) { render_inner(&) }
          end
        end

        private

        def render_inner(&block)
          render(@icon) if @icon
          block&.call
          render(@icon_right) if @icon_right
        end

        def full_style
          base = "display: inline-flex; align-items: center; justify-content: center; gap: #{@size[:gap]}px; " \
                 "padding: #{@size[:padding]}; font-size: #{@size[:font_size]}px; font-weight: 500; " \
                 "border-radius: #{@size[:radius]}; #{@variant} " \
                 "width: #{@full ? '100%' : 'auto'}; " \
                 "opacity: #{@disabled ? 0.5 : 1}; cursor: #{@disabled ? 'not-allowed' : 'pointer'}; " \
                 'text-decoration: none; line-height: 1.2;'
          @extra_style ? "#{base} #{@extra_style}" : base
        end
      end
    end
  end
end
