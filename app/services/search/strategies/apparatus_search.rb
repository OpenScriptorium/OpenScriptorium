module Search
  module Strategies
    class ApparatusSearch
      # Find verses that have textual variants (variant_units). Optionally
      # scoped to a work and/or variant type.

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100

      def initialize(scope: nil, variant_type: nil, page: 1, per_page: DEFAULT_LIMIT)
        @scope = scope
        @variant_type = variant_type
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        offset = (@page - 1) * @per_page

        # Find canonical_refs that have variant_units, then find work_units
        # for those refs.
        vu_base = VariantUnit.joins(canonical_ref: { work_units: :work })
        vu_base = vu_base.where(variant_type: @variant_type) if @variant_type.present?

        if @scope.is_a?(Hash) && @scope[:work].present?
          vu_base = vu_base.where(works: { slug: @scope[:work] })
        end

        # Get distinct canonical_ref_ids with variants
        cref_ids = vu_base.distinct.pluck("canonical_refs.id")
        total = cref_ids.size

        # Paginate the cref_ids, then load work_units
        paged_cref_ids = cref_ids.sort[offset, @per_page] || []

        work_units = WorkUnit
          .where(canonical_ref_id: paged_cref_ids)
          .joins(:canonical_ref, :work)
          .includes(:canonical_ref, work: :license)

        if @scope.is_a?(Hash) && @scope[:work].present?
          work_units = work_units.where(works: { slug: @scope[:work] })
        end

        work_units = work_units.order("canonical_refs.ord")

        # Load variant info for each ref
        variants_by_ref = VariantUnit
          .where(canonical_ref_id: paged_cref_ids)
          .includes(:readings)
          .group_by(&:canonical_ref_id)

        results = work_units.map { |wu| format_result(wu, variants_by_ref[wu.canonical_ref_id]) }

        ResultSet.new(
          results: results,
          query: apparatus_query_label,
          query_type: :apparatus,
          total_count: total,
          page: @page,
          per_page: @per_page
        )
      end

      private

      def format_result(wu, variant_units)
        variant_summary = (variant_units || []).map { |vu|
          readings = vu.readings.map(&:text).join(" / ")
          "#{vu.variant_type}: #{vu.lemma_text} → #{readings}"
        }.join("; ")

        {
          id: wu.id,
          work_slug: wu.work.slug,
          work_title: wu.work.title,
          language: wu.work.language,
          canonical_ref_id: wu.canonical_ref_id,
          citation: wu.canonical_ref.sbl_citation || wu.canonical_ref.display_label,
          hierarchy: wu.canonical_ref.hierarchy,
          body: wu.body,
          headline: wu.body,
          relevance: 1.0,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key,
          variant_summary: variant_summary
        }
      end

      def apparatus_query_label
        parts = ["Verses with textual variants"]
        parts << "(#{@variant_type})" if @variant_type.present?
        parts.join(" ")
      end
    end
  end
end
