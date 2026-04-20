module Api
  module V1
    class ApparatusController < BaseController
      # GET /api/v1/apparatus?book=genesis&chapter=1&verse=1
      # Returns variant units, readings, and witnesses for a passage.
      def index
        cw = CanonicalWork.find_by!(slug: params[:book])
        chapter = params[:chapter].to_i

        crefs = if params[:verse]
          CanonicalRef.where(canonical_work_id: cw.id, hierarchy: [chapter, params[:verse].to_i])
        else
          CanonicalRef.where(canonical_work_id: cw.id).where("hierarchy[1] = ?", chapter)
        end

        raise ActiveRecord::RecordNotFound if crefs.empty?

        variant_units = VariantUnit
          .where(canonical_ref_id: crefs.select(:id))
          .includes(readings: { reading_witnesses: :manuscript })
          .order(:id)

        render json: {
          source: { book: cw.slug, chapter: chapter, verse: params[:verse]&.to_i }.compact,
          variant_units: variant_units.map { |vu| variant_unit_json(vu) }
        }
      end

      private

      def variant_unit_json(vu)
        {
          id: vu.id,
          reference: vu.canonical_ref&.sbl_citation,
          variant_type: vu.variant_type,
          lemma_text: vu.lemma_text,
          context_before: vu.context_before,
          context_after: vu.context_after,
          readings: vu.readings.map { |r| reading_json(r) }
        }
      end

      def reading_json(r)
        {
          id: r.id,
          text: r.text,
          is_base: r.variant_unit.base_reading_id == r.id,
          witnesses: r.reading_witnesses.map { |rw| witness_json(rw) }
        }
      end

      def witness_json(rw)
        ms = rw.manuscript
        {
          siglum: ms.siglum,
          gregory_aland: ms.gregory_aland_number,
          correction_layer: rw.correction_layer,
          certainty: rw.certainty,
          folio: rw.folio,
          is_lacuna: rw.is_lacuna,
          is_supplement: rw.is_supplement
        }
      end
    end
  end
end
