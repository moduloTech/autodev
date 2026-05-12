# frozen_string_literal: true

module Web
  # Builds a filtered + paginated issues dataset from the request params.
  # Pure helpers — no Sinatra coupling so it's easy to test in isolation.
  module IssuesFilter
    PER_PAGE_OPTIONS = [20, 50, 100].freeze
    DEFAULT_PER_PAGE = 50
    TABS = %w[active pending errors waiting done all].freeze

    def filter_issues(params, base = issues_dataset)
      ds = apply_tab(base, tab_param(params))
      ds = apply_keyword(ds, params[:q])
      ds = apply_date_from(ds, params[:from])
      ds = apply_date_to(ds, params[:to])
      ds.order(Sequel.desc(:id))
    end

    def tab_param(params)
      raw = params[:tab].to_s
      TABS.include?(raw) ? raw : 'all'
    end

    def apply_tab(dataset, tab)
      case tab
      when 'active'  then dataset.where(status: Dashboard::ACTIVE_STATES)
      when 'pending' then dataset.where(status: 'pending')
      when 'errors'  then dataset.where(status: 'error')
      when 'waiting' then dataset.where(status: 'needs_clarification')
      when 'done'    then dataset.where(status: 'done')
      else dataset
      end
    end

    # Counts per tab on the unfiltered dataset, used to populate the
    # numeric pill on each tab. 6 cheap queries.
    def tab_counts
      ds = issues_dataset
      {
        active: ds.where(status: Dashboard::ACTIVE_STATES).count,
        pending: ds.where(status: 'pending').count,
        errors: ds.where(status: 'error').count,
        waiting: ds.where(status: 'needs_clarification').count,
        done: ds.where(status: 'done').count,
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
      rows = dataset.limit(per_page).offset((page - 1) * per_page).all
      [rows, total, total_pages, page]
    end

    private

    def apply_keyword(dataset, query)
      return dataset if query.nil? || query.strip.empty?

      escaped = query.strip.gsub('%', '\\%').gsub('_', '\\_')
      dataset.where(Sequel.ilike(:issue_title, "%#{escaped}%"))
    end

    def apply_date_from(dataset, from_date)
      return dataset if from_date.nil? || from_date.empty?

      dataset.where { created_at >= from_date }
    end

    def apply_date_to(dataset, to_date)
      return dataset if to_date.nil? || to_date.empty?

      # End-of-day inclusive: anything strictly before 00:00 the next day.
      dataset.where { created_at < "#{to_date} 23:59:59" }
    end
  end
end
