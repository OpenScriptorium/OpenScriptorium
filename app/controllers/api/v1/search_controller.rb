module Api
  module V1
    class SearchController < BaseController
      # GET /api/v1/search?q=in+the+beginning&work=bsb&limit=25
      #
      # Scoping params (all optional):
      #   work       - slug of a specific work (e.g. "bsb")
      #   book       - slug of a canonical work / book (e.g. "genesis")
      #   section[]  - testament/section filter: ot, nt, deuterocanon, pseudepigrapha, etc.
      #   tradition[]- tradition filter: ש, χ, academic, etc.
      #   language   - single language code (e.g. "en", "grc")
      #   work_types - "all" to include commentary/treatise, otherwise defaults to scripture
      #   features[] - feature flags (e.g. "has_lemmas", "has_notes")
      def index
        query = params[:q].to_s.strip
        render json: { error: "query required" }, status: :bad_request and return if query.blank?

        limit = [[params.fetch(:limit, 25).to_i, 1].max, 100].min
        page  = [params.fetch(:page, 1).to_i, 1].max

        scope = build_scope

        result = Search::Cache.fetch(query, scope: scope, page: page, per_page: limit) do
          Search::Executor.new(
            query,
            scope: scope.presence,
            page: page,
            per_page: limit
          ).call
        end

        if result.redirect?
          render json: { query: query, redirect: result.redirect }
          return
        end

        total_pages = (result.total_count.to_f / limit).ceil

        json = {
          query: query,
          query_type: result.query_type,
          count: result.total_count,
          page: result.page,
          per_page: result.per_page,
          total_pages: total_pages,
          results: result.results.map { |r|
            {
              work: r[:work_slug],
              reference: r[:citation],
              hierarchy: r[:hierarchy],
              body: r[:body],
              headline: r[:headline],
              license: r[:license]
            }
          },
          cross_language: result.cross_language_card
        }

        # next_page / prev_page links
        if page < total_pages
          json[:next_page] = page + 1
        end
        if page > 1
          json[:prev_page] = page - 1
        end

        render json: json
      end

      # GET /api/v1/search/completions?q=gen
      # Returns type-ahead suggestions for books, works, and authors.
      def completions
        q = params[:q].to_s.strip
        return render json: [] if q.length < 2

        results = []
        safe_q = ApplicationRecord.sanitize_sql_like(q)

        CanonicalWork.where("title ILIKE ? OR sbl_abbreviation ILIKE ?", "%#{safe_q}%", "%#{safe_q}%")
                     .order(:position)
                     .limit(5)
                     .each { |cw| results << { type: "book", slug: cw.slug, label: cw.title, testament: cw.testament } }

        Work.where("title ILIKE ? OR slug ILIKE ?", "%#{safe_q}%", "%#{safe_q}%")
            .order(:title)
            .limit(5)
            .each { |w| results << { type: "work", slug: w.slug, label: w.title, language: w.language, work_type: w.work_type } }

        render json: results
      end

      private

      def build_scope
        scope = {}
        scope[:work] = params[:work] if params[:work].present?
        scope[:book] = params[:book] if params[:book].present?
        scope[:language] = params[:language] if params[:language].present?
        scope[:work_types] = params[:work_types] if params[:work_types].present?

        sections = Array(params[:section]).select(&:present?)
        scope[:sections] = sections if sections.any?

        traditions = Array(params[:tradition]).select(&:present?)
        scope[:traditions] = traditions if traditions.any?

        features = Array(params[:features]).select(&:present?)
        scope[:features] = features if features.any?

        scope
      end
    end
  end
end
