module Search
  class ResultSet
    attr_reader :results, :query, :query_type, :total_count, :facets,
                :cross_language_card, :redirect, :page, :per_page

    def initialize(results: [], query: "", query_type: :text, total_count: 0,
                   facets: {}, cross_language_card: nil, redirect: nil,
                   page: 1, per_page: 25)
      @results = results
      @query = query
      @query_type = query_type
      @total_count = total_count
      @facets = facets
      @cross_language_card = cross_language_card
      @redirect = redirect
      @page = page.to_i.nonzero? || 1
      @per_page = per_page.to_i.nonzero? || 25
    end

    def redirect?
      redirect.present?
    end

    def empty?
      results.empty?
    end

    def total_pages
      return 0 if per_page.zero?
      (total_count.to_f / per_page).ceil
    end

    # Group results by canonical_ref so parallel translations appear together.
    def grouped_by_reference
      results.group_by { |r| r[:canonical_ref_id] }
    end

    # Group results by work.
    def grouped_by_work
      results.group_by { |r| r[:work_slug] }
    end
  end
end
