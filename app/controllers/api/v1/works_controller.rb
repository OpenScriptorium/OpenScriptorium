module Api
  module V1
    class WorksController < BaseController
      # GET /api/v1/works
      def index
        works = Work.all.order(:slug)
        render json: works.map { |w| work_json(w) }
      end

      # GET /api/v1/works/:slug
      def show
        work = Work.find_by!(slug: params[:slug])
        books = CanonicalWork
                  .joins(canonical_refs: :work_units)
                  .where(work_units: { work_id: work.id })
                  .group("canonical_works.id")
                  .select("canonical_works.*, COUNT(work_units.id) AS unit_count")
                  .order(:position, :title)

        render json: work_json(work).merge(
          books: books.map { |cw|
            { slug: cw.slug, title: cw.title, book_key: cw.book_key,
              testament: cw.testament, unit_count: cw.unit_count }
          }
        )
      end

      private

      def work_json(w)
        {
          slug: w.slug,
          title: w.title,
          native_title: w.native_title,
          language: w.language,
          work_type: w.work_type,
          traditions: w.traditions,
          publication_year: w.publication_year,
          feature_flags: w.feature_flags,
          source_url: w.source_url,
          license: {
            name: w.license.name,
            spdx_id: w.license.spdx_id,
            url: w.license.url,
            attribution_required: w.license.attribution_required,
          },
          description: w.description,
        }
      end
    end
  end
end
