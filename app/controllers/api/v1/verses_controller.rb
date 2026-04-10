module Api
  module V1
    class VersesController < BaseController
      # GET /api/v1/works/:work_slug/:book_slug/:chapter
      # GET /api/v1/works/:work_slug/:book_slug/:chapter/:verse
      def show
        work = Work.find_by!(slug: params[:work_slug])
        canonical_work = resolve_canonical_work(work, params[:book_slug])
        raise ActiveRecord::RecordNotFound unless canonical_work

        base = WorkUnit
                 .joins(:canonical_ref)
                 .where(work_id: work.id,
                        canonical_refs: { canonical_work_id: canonical_work.id })
                 .where("canonical_refs.hierarchy[1] = ?", params[:chapter].to_i)
                 .order("canonical_refs.ord")
                 .includes(:canonical_ref, :work_unit_notes)

        if params[:verse]
          base = base.where("canonical_refs.hierarchy[2] = ?", params[:verse].to_i)
        end

        units = base.to_a
        raise ActiveRecord::RecordNotFound if units.empty?

        render json: {
          work: params[:work_slug],
          book: params[:book_slug],
          chapter: params[:chapter].to_i,
          license: { name: work.license.name, url: work.license.url },
          verses: units.map { |u| verse_json(u) }
        }
      end

      private

      def verse_json(u)
        ref = u.canonical_ref
        json = {
          reference: ref.sbl_citation || ref.display_label,
          hierarchy: ref.hierarchy,
          body: u.body,
          label: u.label,
        }
        if u.work_unit_notes.any?
          json[:notes] = u.work_unit_notes.sort_by(&:position_in_unit).map { |n|
            { type: n.note_type, body: n.body, anchor_text: n.anchor_text }
          }
        end
        if u.markup.present?
          json[:markup] = u.markup
        end
        json
      end

      def resolve_canonical_work(work, book_slug)
        CanonicalWork
          .joins(canonical_refs: :work_units)
          .where(work_units: { work_id: work.id })
          .where(book_key: book_slug)
          .group("canonical_works.id")
          .order(Arel.sql("COUNT(work_units.id) DESC"))
          .first || CanonicalWork.find_by(slug: book_slug)
      end
    end
  end
end
