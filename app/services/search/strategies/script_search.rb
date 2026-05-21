module Search
  module Strategies
    class ScriptSearch
      # Searches for Hebrew or Greek words by their normalized form using
      # trigram indexes. Used when the query is pure Hebrew or Greek script.

      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      HEBREW_POINTS_RE = /[\u0591-\u05BD\u05BF-\u05C7]/

      def initialize(query, script:, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @query = query
        @script = script # :hebrew or :greek
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        normalized_query = normalize_query

        offset = (@page - 1) * @per_page

        # Search words.normalized using trigram similarity
        words_base = Word
          .where("normalized = ? OR normalized % ?", normalized_query, normalized_query)
          .joins(:work_unit, work_unit: [:canonical_ref, :work])
          .includes(:lemma, work_unit: [:canonical_ref, { work: :license }])

        words_base = apply_scope(words_base)

        total = words_base.count
        words = words_base
          .order(Arel.sql("similarity(words.normalized, #{Word.connection.quote(normalized_query)}) DESC"),
                 "works.slug", "canonical_refs.ord")
          .offset(offset)
          .limit(@per_page)

        # Deduplicate: one result per work_unit (verse), not per word
        results = words.map { |w| format_result(w) }.uniq { |r| [r[:id], r[:work_slug]] }

        # Find associated lemma
        lemma = words.first&.lemma
        cross_language_card = lemma ? build_lemma_card(lemma) : nil

        ResultSet.new(
          results: results,
          query: @query,
          query_type: @script,
          total_count: total,
          cross_language_card: cross_language_card,
          page: @page,
          per_page: @per_page
        )
      end

      private

      def normalize_query
        q = @query.strip
        # Strip Hebrew nikud for matching
        q = q.gsub(HEBREW_POINTS_RE, "") if @script == :hebrew
        # Strip Greek diacritics (breathing marks, accents) for matching
        q = q.unicode_normalize(:nfd).gsub(/[\u0300-\u036F]/, "").unicode_normalize(:nfc) if @script == :greek
        q
      end

      def apply_scope(base)
        if @scope.is_a?(Hash)
          base = base.where(works: { slug: @scope[:work] }) if @scope[:work].present?
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

      def build_lemma_card(lemma)
        entry = {
          id: lemma.id,
          lemma: lemma.lemma,
          normalized: lemma.normalized,
          transliteration: lemma.transliteration,
          language: lemma.language,
          primary_gloss: lemma.primary_gloss,
          part_of_speech: lemma.part_of_speech,
          frequency: lemma.frequency
        }
        hebrew = %w[he hbo arc].include?(lemma.language) ? [entry] : []
        greek  = %w[el-koine grc].include?(lemma.language) ? [entry] : []
        { hebrew: hebrew, greek: greek }
      end
    end
  end
end
