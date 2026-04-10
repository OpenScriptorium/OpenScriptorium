module Api
  module V1
    class CrossReferencesController < BaseController
      # GET /api/v1/cross-references?book=genesis&chapter=1&verse=1
      # GET /api/v1/cross-references?book=genesis&chapter=1
      def index
        cw = CanonicalWork.find_by!(slug: params[:book])
        chapter = params[:chapter].to_i

        if params[:verse]
          crefs = CanonicalRef.where(
            canonical_work_id: cw.id,
            hierarchy: [chapter, params[:verse].to_i]
          )
        else
          crefs = CanonicalRef.where(canonical_work_id: cw.id)
                              .where("hierarchy[1] = ?", chapter)
        end

        raise ActiveRecord::RecordNotFound if crefs.empty?

        ords = crefs.pluck(:ord)
        min_ord, max_ord = ords.minmax

        xrefs = CrossReference.approved
                  .where(source_canonical_work_id: cw.id)
                  .where("source_range && int4range(?, ?)", min_ord, max_ord + 1)
                  .includes(:target_canonical_work)
                  .limit(500)

        render json: {
          source: { book: cw.slug, chapter: chapter, verse: params[:verse]&.to_i }.compact,
          cross_references: xrefs.map { |xr| xref_json(xr) }
        }
      end

      private

      def xref_json(xr)
        target_cw = xr.target_canonical_work
        start_ref = CanonicalRef.where(canonical_work_id: target_cw.id,
                                       ord: xr.target_range.begin).first
        {
          target_book: target_cw.slug,
          target_reference: start_ref&.sbl_citation || target_cw.title,
          target_hierarchy: start_ref&.hierarchy,
          relationship_type: xr.relationship_type,
          confidence: xr.confidence,
          source_dataset: xr.source_dataset,
        }
      end
    end
  end
end
