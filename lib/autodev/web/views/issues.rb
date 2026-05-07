# frozen_string_literal: true

module Web
  module Views
    # GET /issues — full filtered list with keyword/date filters and pagination.
    class Issues < Base # rubocop:disable Metrics/ClassLength
      def initialize(issues:, total:, total_pages:, page:, per_page:, filters:, **) # rubocop:disable Metrics/ParameterLists
        super(**)
        @issues = issues
        @total = total
        @total_pages = total_pages
        @page = page
        @per_page = per_page
        @filters = filters
      end

      def view_template
        with_layout do
          h1 { t_web(:web_issues_title) }
          render_filter_form
          p(class: 'muted') do
            t_web(:web_issues_count_paginated, count: @total, page: @page, total: @total_pages)
          end
          render_results
        end
      end

      FORM_STYLE = 'margin-bottom: 1rem; display: flex; gap: 0.6rem; flex-wrap: wrap; align-items: end;'

      def render_filter_form
        form(method: 'get', action: '/issues', style: FORM_STYLE) do
          render_keyword_input
          render_date_input(:from, :web_issues_from)
          render_date_input(:to, :web_issues_to)
          render_per_page_select
          button(type: 'submit') { t_web(:web_issues_filter) }
          a(href: '/issues', class: 'muted') { t_web(:web_issues_reset) }
        end
      end

      def render_keyword_input
        label do
          plain t_web(:web_issues_search)
          plain ' '
          input(type: 'text', name: 'q', value: @filters[:q].to_s,
                placeholder: t_web(:web_issues_search_placeholder),
                style: 'min-width: 14rem')
        end
      end

      def render_date_input(field, label_key)
        label do
          plain t_web(label_key)
          plain ' '
          input(type: 'date', name: field.to_s, value: @filters[field].to_s)
        end
      end

      def render_per_page_select # rubocop:disable Metrics/MethodLength
        label do
          plain t_web(:web_issues_per_page)
          plain ' '
          select(name: 'per_page') do
            Web::IssuesFilter::PER_PAGE_OPTIONS.each do |opt|
              if opt == @per_page
                option(value: opt.to_s, selected: true) { opt.to_s }
              else
                option(value: opt.to_s) { opt.to_s }
              end
            end
          end
        end
      end

      def render_results
        if @issues.empty?
          p(class: 'muted') { t_web(:web_issues_no_match) }
        else
          render_table
          render_pager if @total_pages > 1
        end
      end

      def render_table
        table do
          tr do
            %i[web_col_project web_col_iid web_col_status web_col_title web_col_created_at web_col_mr]
              .each { |k| th { t_web(k) } }
          end
          @issues.each { |row| render_row(row) }
        end
      end

      def render_row(row) # rubocop:disable Metrics/AbcSize
        tr do
          td { a(href: "/projects/#{project_slug(row[:project_path])}") { row[:project_path] } }
          td { a(href: "/issues/#{row[:id]}") { plain "##{row[:issue_iid]}" } }
          td { render status_pill(row[:status]) }
          td { row[:issue_title] }
          td(class: 'muted') { row[:created_at] }
          td { render_mr_link(row) }
        end
      end

      def render_mr_link(row)
        return unless row[:mr_url] && !row[:mr_url].empty?

        a(href: row[:mr_url], target: '_blank', rel: 'noopener') { plain "!#{row[:mr_iid]}" }
      end

      def render_pager
        p do
          a(href: page_link(@page - 1)) { t_web(:web_issues_prev) } if @page > 1
          plain ' '
          span(class: 'muted') { plain " #{t_web(:web_issues_page_indicator, page: @page, total: @total_pages)} " }
          plain ' '
          a(href: page_link(@page + 1)) { t_web(:web_issues_next) } if @page < @total_pages
        end
      end

      def page_link(page)
        params = @filters.merge(per_page: @per_page, page: page).reject { |_, v| v.nil? || v == '' }
        "?#{URI.encode_www_form(params)}"
      end
    end
  end
end
