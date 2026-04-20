module Search
  module Strategies
    class CitationSearch
      def initialize(query)
        @query = query
      end

      def call
        parsed = CitationParser.parse(@query)

        unless parsed
          # Citation looked plausible but couldn't parse — fall back to text search
          return TextSearch.new(@query).call
        end

        resolved = CitationParser.resolve(@query)

        unless resolved
          return TextSearch.new(@query).call
        end

        redirect = build_redirect_path(resolved)
        results = fetch_results(parsed)

        if results.any?
          ResultSet.new(
            query: @query,
            query_type: :citation,
            results: results,
            total_count: results.size,
            redirect: redirect
          )
        else
          # Parsed and resolved but no work_units found — fall back to text search
          TextSearch.new(@query).call
        end
      end

      private

      def fetch_results(parsed)
        canonical_work_id = parsed.canonical_work_id
        chapter = parsed.chapter
        verse = parsed.verse
        end_verse = parsed.end_verse

        # Build the hierarchy prefix to match canonical_refs
        refs = if verse && end_verse
                 # Range: Gen 1:1-5 → hierarchy IN ([1,1], [1,2], [1,3], [1,4], [1,5])
                 CanonicalRef.where(canonical_work_id: canonical_work_id)
                             .where("hierarchy[1] = ? AND hierarchy[2] >= ? AND hierarchy[2] <= ?",
                                    chapter, verse, end_verse)
               elsif verse
                 # Single verse: Gen 1:1 → hierarchy = [1, 1]
                 CanonicalRef.where(canonical_work_id: canonical_work_id,
                                    hierarchy: [chapter, verse])
               else
                 # Whole chapter: Gen 1 → hierarchy[1] = 1
                 CanonicalRef.where(canonical_work_id: canonical_work_id)
                             .where("hierarchy[1] = ?", chapter)
               end

        ref_ids = refs.pluck(:id)
        return [] if ref_ids.empty?

        # Also check sibling canonical_works with the same sbl_abbreviation
        # (e.g. "Genesis" and "Genesis (MT)" share the same abbreviation)
        sbl_abbr = CanonicalWork.where(id: canonical_work_id).pick(:sbl_abbreviation)
        if sbl_abbr.present?
          sibling_ids = CanonicalWork.where(sbl_abbreviation: sbl_abbr)
                                     .where.not(id: canonical_work_id)
                                     .pluck(:id)
          if sibling_ids.any?
            sibling_refs = if verse && end_verse
                             CanonicalRef.where(canonical_work_id: sibling_ids)
                                         .where("hierarchy[1] = ? AND hierarchy[2] >= ? AND hierarchy[2] <= ?",
                                                chapter, verse, end_verse)
                           elsif verse
                             CanonicalRef.where(canonical_work_id: sibling_ids,
                                                hierarchy: [chapter, verse])
                           else
                             CanonicalRef.where(canonical_work_id: sibling_ids)
                                         .where("hierarchy[1] = ?", chapter)
                           end
            ref_ids += sibling_refs.pluck(:id)
          end
        end

        WorkUnit.joins(:canonical_ref, :work)
                .where(canonical_ref_id: ref_ids)
                .includes(:canonical_ref, work: :license)
                .order(Arel.sql(
                  "canonical_refs.hierarchy ASC, " \
                  "CASE works.work_type " \
                  "  WHEN 'scripture_translation' THEN 0 " \
                  "  WHEN 'scripture_original' THEN 1 " \
                  "  ELSE 2 END, " \
                  "CASE WHEN works.language = 'en' THEN 0 ELSE 1 END, " \
                  "CASE works.slug " \
                  "  WHEN 'bsb' THEN 0 WHEN 'kjv' THEN 1 " \
                  "  WHEN 'webbe' THEN 2 ELSE 3 END, " \
                  "works.slug"
                ))
                .map { |wu| format_result(wu) }
      end

      def format_result(wu)
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
          relevance: 10.0,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key
        }
      end

      def build_redirect_path(resolved)
        path = "/#{resolved[:work_slug]}/#{resolved[:book_slug]}"
        if resolved[:verse] && resolved[:end_verse]
          "#{path}/#{resolved[:chapter]}/#{resolved[:verse]}-#{resolved[:end_verse]}"
        elsif resolved[:verse]
          "#{path}/#{resolved[:chapter]}/#{resolved[:verse]}"
        elsif resolved[:chapter]
          "#{path}/#{resolved[:chapter]}"
        else
          path
        end
      end
    end
  end
end
