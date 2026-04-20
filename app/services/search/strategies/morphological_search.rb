module Search
  module Strategies
    class MorphologicalSearch
      # Morphological pattern search — requires a work scope to avoid full
      # table scan on 2.2M words. Pattern uses * as wildcard (converted to %).

      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      def initialize(query, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @query = query
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        unless @scope.is_a?(Hash) && @scope[:work].present?
          return ResultSet.new(
            query: @query,
            query_type: :morphological,
            results: [],
            total_count: 0
          )
        end

        pattern = @query.tr("*", "%")
        offset = (@page - 1) * @per_page

        words_base = Word
          .where("morph_code LIKE ?", pattern)
          .where(work: Work.where(slug: @scope[:work]))
          .joins(:work_unit, work_unit: [:canonical_ref, :work])
          .includes(:lemma, work_unit: [:canonical_ref, { work: :license }])

        total = words_base.count
        words = words_base
          .order("canonical_refs.ord")
          .offset(offset)
          .limit(@per_page)

        results = words.map { |w| format_result(w) }

        ResultSet.new(
          results: results,
          query: @query,
          query_type: :morphological,
          total_count: total,
          page: @page,
          per_page: @per_page
        )
      end

      private

      def format_result(word)
        wu = word.work_unit
        {
          id: wu.id,
          work_slug: wu.work.slug,
          work_title: wu.work.title,
          language: wu.work.language,
          canonical_ref_id: wu.canonical_ref_id,
          citation: wu.canonical_ref.sbl_citation || wu.canonical_ref.display_label,
          hierarchy: wu.canonical_ref.hierarchy,
          body: wu.body,
          headline: highlight_word(wu.body, word.surface),
          relevance: 1.0,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key,
          word_surface: word.surface,
          morph_code: word.morph_code,
          lemma_gloss: word.lemma&.primary_gloss
        }
      end

      def highlight_word(body, surface)
        return body if surface.blank? || body.blank?
        body.gsub(/(#{Regexp.escape(surface)})/i, '<mark>\1</mark>')
      end
    end
  end
end
