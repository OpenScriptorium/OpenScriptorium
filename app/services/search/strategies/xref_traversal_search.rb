module Search
  module Strategies
    class XrefTraversalSearch
      # Find all verses that are cross-referenced to/from a given passage.
      # Input: a citation string (e.g. "Gen 1:1") or canonical_ref_id.
      # Uses the int4range overlap (&&) operator against GIST indexes.

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100

      def initialize(citation, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @citation = citation.to_s.strip
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        parsed = CitationParser.parse(@citation)
        return empty_result unless parsed

        cref = CanonicalRef.where(canonical_work_id: parsed.canonical_work_id)

        if parsed.verse
          cref = cref.where(hierarchy: [parsed.chapter, parsed.verse])
        elsif parsed.chapter
          cref = cref.where("hierarchy[1] = ?", parsed.chapter)
        end

        crefs = cref.to_a
        return empty_result if crefs.empty?

        ord_min = crefs.map(&:ord).min
        ord_max = crefs.map(&:ord).max
        source_range = "(#{ord_min},#{ord_max + 1})"

        # Find cross-references where our passage overlaps the source or target range
        xrefs = CrossReference.where(
          "source_canonical_work_id = :cw_id AND source_range && int4range(:lo, :hi)",
          cw_id: parsed.canonical_work_id, lo: ord_min, hi: ord_max + 1
        ).or(
          CrossReference.where(
            "target_canonical_work_id = :cw_id AND target_range && int4range(:lo, :hi)",
            cw_id: parsed.canonical_work_id, lo: ord_min, hi: ord_max + 1
          )
        ).where(status: "approved")

        # Collect the "other side" of each xref
        target_refs = []
        xrefs.each do |xr|
          if xr.source_canonical_work_id == parsed.canonical_work_id
            target_refs << { canonical_work_id: xr.target_canonical_work_id, range: xr.target_range }
          else
            target_refs << { canonical_work_id: xr.source_canonical_work_id, range: xr.source_range }
          end
        end

        return empty_result if target_refs.empty?

        total = target_refs.size
        offset = (@page - 1) * @per_page
        paged = target_refs[offset, @per_page] || []

        # For each target ref, find a work_unit to display
        results = paged.filter_map { |tr| resolve_target(tr) }

        ResultSet.new(
          results: results,
          query: "Cross-references for #{@citation}",
          query_type: :xref_traversal,
          total_count: total,
          page: @page,
          per_page: @per_page
        )
      end

      private

      def resolve_target(target)
        # Find canonical_refs in the target range
        cref = CanonicalRef
          .where(canonical_work_id: target[:canonical_work_id])
          .where("ord >= ? AND ord < ?", target[:range].begin, target[:range].end)
          .order(:ord)
          .first
        return nil unless cref

        # Find a work_unit for this canonical_ref
        wu = WorkUnit.where(canonical_ref: cref)
                     .joins(:work)
                     .includes(:canonical_ref, work: :license)

        if @scope.is_a?(Hash) && @scope[:work].present?
          wu = wu.where(works: { slug: @scope[:work] })
        end

        wu = wu.first
        return nil unless wu

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
          book_slug: wu.canonical_ref.canonical_work.book_key
        }
      end

      def empty_result
        ResultSet.new(query: "Cross-references for #{@citation}", query_type: :xref_traversal)
      end
    end
  end
end
