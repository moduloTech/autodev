# frozen_string_literal: true

module Web
  module Views
    module Components
      # Autodev brand mark — stacked-cards "</>" SVG.
      # Mirrors primitives.jsx::AutodevLogoMark / AutodevLogo.
      class Logo < Phlex::HTML
        MARK_SVG_TEMPLATE = <<~SVG
          <svg width="%<size>s" height="%<size>s" viewBox="0 0 56 56" fill="none" aria-hidden="true" style="flex: 0 0 auto; display: block;">
            <rect x="20" y="20" width="30" height="30" rx="7" fill="#4A35C9"/>
            <path d="M48 38 Q 48 48 38 48" stroke="#B5A8FA" stroke-width="1.6" stroke-linecap="round" stroke-dasharray="2 3" fill="none" opacity="0.85"/>
            <rect x="6" y="6" width="30" height="30" rx="7" fill="#8771F4"/>
            <path d="M16 16 L11 21 L16 26" stroke="white" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
            <path d="M26 16 L31 21 L26 26" stroke="white" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
            <path d="M24 14 L18 28" stroke="white" stroke-width="2.4" stroke-linecap="round"/>
            <circle cx="42" cy="14" r="3.6" fill="#FFFFFF" stroke="#4A35C9" stroke-width="2"/>
            <circle cx="14" cy="42" r="3.6" fill="#FFFFFF" stroke="#4A35C9" stroke-width="2"/>
          </svg>
        SVG
        def initialize(size: 28, with_word: true) # rubocop:disable Lint/MissingSuper
          @size = size
          @with_word = with_word
        end

        def view_template
          span(style: 'display: inline-flex; align-items: center; gap: 8px; color: var(--text-strong);') do
            raw safe(format(MARK_SVG_TEMPLATE, size: @size))
            if @with_word
              word_size = (@size * 0.7).round
              span(style: "font-weight: 700; letter-spacing: -0.4px; font-size: #{word_size}px;") { 'autodev' }
            end
          end
        end
      end
    end
  end
end
