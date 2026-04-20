module Search
  module Strategies
    class StrongsSearch
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      def initialize(query, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @query = query.upcase
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        offset = (@page - 1) * @per_page

        # Match both "H430" and "430" formats since sources vary
        number_only = @query.sub(/\A[HG]/, "")
        prefix = @query[0]

        words_base = Word
          .where("strongs_number = ? OR strongs_number = ?", @query, number_only)
          .joins(:work_unit, work_unit: [:canonical_ref, :work])
          .includes(:lemma, work_unit: [:canonical_ref, { work: :license }])

        words_base = apply_scope(words_base)

        total = words_base.count
        words = words_base
          .order("works.slug", "canonical_refs.ord")
          .offset(offset)
          .limit(@per_page)

        # Find the best lemma for the sidebar card — filter by language
        # based on H/G prefix to avoid cross-language contamination.
        # Prefer ones with STEP-imported glosses (not empty), then highest frequency.
        lang_filter = prefix == "H" ? %w[he hbo arc] : %w[el-koine grc]
        lemma = Lemma.joins(:words)
                     .where(words: { strongs_number: [@query, number_only] })
                     .where(lemmas: { language: lang_filter })
                     .order(Arel.sql("CASE WHEN lemmas.primary_gloss IS NOT NULL AND lemmas.primary_gloss != '' THEN 0 ELSE 1 END, lemmas.frequency DESC"))
                     .first

        # Deduplicate: one result per work_unit (verse), not per word
        results = deduplicate_results(words.map { |w| format_result(w) })

        cross_language_card = lemma ? build_lemma_card(lemma) : nil

        ResultSet.new(
          results: results,
          query: @query,
          query_type: :strongs,
          total_count: total,
          cross_language_card: cross_language_card,
          page: @page,
          per_page: @per_page
        )
      end

      private

      def apply_scope(base)
        if @scope.is_a?(Hash) && @scope[:work].present?
          base = base.where(works: { slug: @scope[:work] })
        end
        base
      end

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
          morph_code: word.morph_code
        }
      end

      def highlight_word(body, surface)
        return body if surface.blank? || body.blank?
        body.gsub(/(#{Regexp.escape(surface)})/i, '<mark>\1</mark>')
      end

      def deduplicate_results(results)
        results.uniq { |r| [r[:id], r[:work_slug]] }
      end

      def build_lemma_card(lemma)
        entry = {
          lemma: lemma.lemma,
          normalized: lemma.normalized,
          transliteration: lemma.transliteration,
          language: lemma.language,
          primary_gloss: lemma.primary_gloss,
          part_of_speech: lemma.part_of_speech,
          frequency: lemma.frequency,
          strongs_number: @query
        }
        hebrew = %w[he hbo arc].include?(lemma.language) ? [entry] : []
        greek  = %w[el-koine grc].include?(lemma.language) ? [entry] : []
        { hebrew: hebrew, greek: greek }
      end
    end
  end
end
