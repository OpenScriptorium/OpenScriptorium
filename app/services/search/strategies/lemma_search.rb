module Search
  module Strategies
    class LemmaSearch
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      def initialize(query, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @query = query
        @normalized_query = strip_diacritics(query)
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        lemmas = find_lemmas
        return empty_result if lemmas.empty?

        offset = (@page - 1) * @per_page

        words_base = Word
          .where(lemma_id: lemmas.map(&:id))
          .joins(:work_unit, work_unit: [:canonical_ref, :work])
          .includes(:lemma, work_unit: [:canonical_ref, { work: :license }])

        words_base = apply_scope(words_base)

        total = words_base.count
        words = words_base
          .order("works.slug", "canonical_refs.ord")
          .offset(offset)
          .limit(@per_page)

        # Deduplicate: one result per work_unit (verse), not per word
        results = words.map { |w| format_result(w) }.uniq { |r| [r[:id], r[:work_slug]] }
        primary_lemma = lemmas.first
        cross_language_card = build_lemma_card(primary_lemma)

        ResultSet.new(
          results: results,
          query: @query,
          query_type: :lemma,
          total_count: total,
          cross_language_card: cross_language_card,
          page: @page,
          per_page: @per_page
        )
      end

      private

      # Prefer common words (lowercase gloss) over proper names (capitalized),
      # then highest frequency. Prevents "shalom" → Shallum, "אמר" → Immer.
      PREFER_COMMON = "CASE WHEN primary_gloss ~ '^[a-z]' THEN 0 ELSE 1 END, frequency DESC"

      def find_lemmas
        # Try exact normalized match first (diacritics already stripped)
        found = Lemma.where(normalized: @normalized_query)
                     .where("frequency > 0")
                     .order(Arel.sql(PREFER_COMMON))
        return found.to_a if found.exists?

        # Also try the raw query (handles Hebrew consonantal forms)
        found = Lemma.where(normalized: @query)
                     .where("frequency > 0")
                     .order(Arel.sql(PREFER_COMMON))
        return found.to_a if found.exists?

        # Try transliteration match
        found = Lemma.where("transliteration ILIKE ?", @query)
                     .where("frequency > 0")
                     .order(Arel.sql(PREFER_COMMON))
        return found.to_a if found.exists?

        # Try trigram similarity on normalized
        quoted = Lemma.connection.quote(@normalized_query)
        found = Lemma.where("normalized % ?", @normalized_query)
                     .where("frequency > 0")
                     .order(Arel.sql("CASE WHEN primary_gloss ~ '^[a-z]' THEN 0 ELSE 1 END, similarity(normalized, #{quoted}) DESC, frequency DESC"))
                     .limit(5)
        return found.to_a if found.exists?

        []
      end

      # Strip Greek accents/breathings and Hebrew niqqud/cantillation
      def strip_diacritics(str)
        str.to_s
           .unicode_normalize(:nfd)
           .gsub(/[\u0300-\u036F\u0591-\u05BD\u05BF-\u05C7]/, "")
      end

      def apply_scope(base)
        if @scope.is_a?(Hash)
          base = base.where(works: { slug: @scope[:work] }) if @scope[:work].present?
          base = base.where(works: { language: @scope[:language] }) if @scope[:language].present?
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
          frequency: lemma.frequency,
          senses: lemma.senses
        }
        hebrew = %w[he hbo arc].include?(lemma.language) ? [entry] : []
        greek  = %w[el-koine grc].include?(lemma.language) ? [entry] : []
        { hebrew: hebrew, greek: greek }
      end

      def empty_result
        ResultSet.new(query: @query, query_type: :lemma)
      end
    end
  end
end
