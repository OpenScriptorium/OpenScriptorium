module Api
  module V1
    class SearchController < BaseController
      # GET /api/v1/search?q=in+the+beginning&work=bsb&limit=25
      def index
        query = params[:q].to_s.strip
        render json: { error: "query required" }, status: :bad_request and return if query.blank?

        limit = [params.fetch(:limit, 25).to_i, 100].min
        scope = WorkUnit.joins(:canonical_ref, :work)
                        .where("work_units.body ILIKE ?", "%#{WorkUnit.sanitize_sql_like(query)}%")
                        .includes(:canonical_ref, work: :license)
                        .order("works.slug", "canonical_refs.ord")
                        .limit(limit)

        scope = scope.where(works: { slug: params[:work] }) if params[:work].present?

        results = scope.map do |u|
          {
            work: u.work.slug,
            reference: u.canonical_ref.sbl_citation || u.canonical_ref.display_label,
            hierarchy: u.canonical_ref.hierarchy,
            body: u.body,
            license: u.work.license.name,
          }
        end

        render json: { query: query, count: results.size, results: results }
      end
    end
  end
end
