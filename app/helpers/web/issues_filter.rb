# frozen_string_literal: true

module Web
  # Builds a filtered + paginated issues dataset from the request params.
  # Pure helpers — no Sinatra coupling so it's easy to test in isolation.
  module IssuesFilter
    PER_PAGE_OPTIONS = [20, 50, 100].freeze
    DEFAULT_PER_PAGE = 50
    TABS = %w[active pending errors waiting delivered_review done closed all].freeze

    def filter_issues(params, base = issues_dataset)
      ds = apply_tab(base, tab_param(params))
      ds = apply_keyword(ds, params[:q])
      ds = apply_date_from(ds, params[:from])
      ds = apply_date_to(ds, params[:to])
      ds.order(id: :desc)
    end

    def tab_param(params)
      raw = params[:tab].to_s
      TABS.include?(raw) ? raw : 'all'
    end

    def apply_tab(dataset, tab) # rubocop:disable Metrics/CyclomaticComplexity
      case tab
      when 'active'  then dataset.where(status: Dashboard::ACTIVE_STATES)
      when 'pending' then dataset.where(status: 'pending')
      when 'errors'  then dataset.where(status: 'error')
      when 'waiting' then dataset.where(status: 'needs_clarification')
      when 'delivered_review' then delivered_review_scope(dataset)
      when 'done'    then dataset.where(status: 'done')
      when 'closed'  then dataset.where(status: 'closed')
      else dataset
      end
    end

    # "Delivered but flagged for a human": done issues that gave up
    # (needs_attention) or whose post-completion hook failed. Shared by the
    # `delivered_review` tab filter, its count, and the dashboard KPI so the
    # three never drift apart.
    def delivered_review_scope(dataset)
      dataset.where(status: 'done')
             .where('needs_attention = ? OR post_completion_error IS NOT NULL', true)
    end

    # Counts per tab on the unfiltered dataset, used to populate the
    # numeric pill on each tab. 7 cheap queries.
    def tab_counts # rubocop:disable Metrics/MethodLength
      ds = issues_dataset
      {
        active: ds.where(status: Dashboard::ACTIVE_STATES).count,
        pending: ds.where(status: 'pending').count,
        errors: ds.where(status: 'error').count,
        waiting: ds.where(status: 'needs_clarification').count,
        delivered_review: delivered_review_scope(ds).count,
        done: ds.where(status: 'done').count,
        closed: ds.where(status: 'closed').count,
        all: ds.count
      }
    end

    def per_page_for(params)
      raw = params[:per_page].to_i
      PER_PAGE_OPTIONS.include?(raw) ? raw : DEFAULT_PER_PAGE
    end

    def page_for(params)
      n = params[:page].to_i
      n.positive? ? n : 1
    end

    # Returns [rows, total_count, total_pages] for the given dataset.
    def paginate(dataset, page, per_page)
      total = dataset.count
      total_pages = [(total / per_page.to_f).ceil, 1].max
      page = total_pages if page > total_pages
      rows = dataset.limit(per_page).offset((page - 1) * per_page).to_a
      [rows, total, total_pages, page]
    end

    private

    def apply_keyword(dataset, query)
      return dataset if query.nil? || query.strip.empty?

      escaped = query.strip.gsub('%', '\\%').gsub('_', '\\_')
      # SQLite's LIKE is case-insensitive by default (CI for ASCII),
      # matching Sequel.ilike's behaviour on the same DB.
      dataset.where('issue_title LIKE ?', "%#{escaped}%")
    end

    def apply_date_from(dataset, from_date)
      return dataset if from_date.nil? || from_date.empty?

      dataset.where('created_at >= ?', from_date)
    end

    def apply_date_to(dataset, to_date)
      return dataset if to_date.nil? || to_date.empty?

      # End-of-day inclusive: anything strictly before 00:00 the next day.
      dataset.where('created_at < ?', "#{to_date} 23:59:59")
    end
  end
end
