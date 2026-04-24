module Search
  module Strategies
    class ConceptRetrieval
      # Bridges natural-language concepts ("the cross", "burning bush")
      # to curated signature verses via the search_concepts table.
      # Fires alongside the normal FTS / semantic / person-topic pipeline
      # and is merged into the final ResultSet; does not replace any
      # existing strategy.
      #
      # See SEARCH_PLAN.md Phase 2 for the design and intended weights.

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100

      # Final score = role_weight * pair_weight * BOOST_MULTIPLIER.
      # Tuned so a signature match (role=1.0, weight=1.0) scores 3.0 —
      # beats weak FTS matches (typically 0.1–0.8) but sits below pinned
      # alias matches and strong phrase hits (>5.0). Raise if signature
      # verses are being buried; lower if false-positive concept
      # matches are drowning out legitimate FTS results.
      BOOST_MULTIPLIER = 3.0

      ROLE_WEIGHTS = {
        "signature" => 1.0,
        "climax"    => 0.9,
        "quote"     => 0.8,
        "context"   => 0.5
      }.freeze

      def initialize(query, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @raw_query = query.to_s
        @normalized = @raw_query.downcase.gsub(/[?!.,;:'"]/, " ").squeeze(" ").strip
        @scope = scope || {}
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        return empty_result if @normalized.blank?

        concepts = matching_concepts
        return empty_result if concepts.empty?

        concept_by_id = concepts.index_by(&:id)
        verses = SearchConceptVerse
          .where(search_concept_id: concept_by_id.keys)
          .includes(canonical_ref: :canonical_work)

        # Score each verse; when the same canonical_ref is linked by
        # multiple concepts, keep the best score.
        best = {}
        verses.each do |v|
          score = (ROLE_WEIGHTS[v.role] || 0.5) * v.weight.to_f * BOOST_MULTIPLIER
          key = v.canonical_ref_id
          prior = best[key]
          if prior.nil? || prior[:relevance] < score
            best[key] = {
              canonical_ref: v.canonical_ref,
              concept: concept_by_id[v.search_concept_id],
              role: v.role,
              relevance: score
            }
          end
        end

        return empty_result if best.empty?

        english_wus = fetch_english_wus(best.keys)
        results = english_wus.map { |wu|
          data = best[wu.canonical_ref_id]
          format_result(wu, data)
        }.sort_by { |r| -r[:relevance] }.first(@per_page)

        ResultSet.new(
          results: results,
          query: @raw_query,
          query_type: :concept,
          total_count: best.size,
          page: @page,
          per_page: @per_page
        )
      end

      # Merge concept results into an existing ResultSet.
      #
      # If the top existing result's body contains a ≥3-word phrase from
      # the query, the user typed a verbatim quote and FTS has already
      # found the source verse. Skip concept merging entirely in that
      # case — annotate the existing top with the matched concept for
      # provenance, but do not change ranks or inject new verses.
      #
      # Otherwise (retrieval-gap mode), merge normally: for each concept
      # verse, add if new or take the higher score if it collides with
      # an existing entry.
      #
      # Returns a new ResultSet; does not mutate.
      def self.merge(existing, concept_result, per_page: 25)
        return existing if concept_result.nil? || concept_result.empty?

        if phrase_match_in_top?(existing, concept_result.query)
          return annotate_only(existing, concept_result)
        end

        by_citation = {}
        existing.results.each { |r| by_citation[r[:citation]] = r }

        concept_result.results.each do |cr|
          prior = by_citation[cr[:citation]]
          if prior.nil?
            by_citation[cr[:citation]] = cr
          elsif cr[:relevance] > prior[:relevance]
            by_citation[cr[:citation]] = prior.merge(
              relevance: cr[:relevance],
              concept_match: cr[:concept_match],
              concept_role: cr[:concept_role]
            )
          else
            by_citation[cr[:citation]] = prior.merge(
              concept_match: cr[:concept_match],
              concept_role: cr[:concept_role]
            )
          end
        end

        merged_results = by_citation.values
          .sort_by { |r| -r[:relevance].to_f }
          .first(per_page)

        ResultSet.new(
          results: merged_results,
          query: existing.query,
          query_type: existing.query_type,
          total_count: existing.total_count + concept_result.total_count,
          facets: existing.facets,
          cross_language_card: existing.cross_language_card,
          redirect: existing.redirect,
          page: existing.page,
          per_page: existing.per_page
        )
      end

      # Exact-quote path: preserve the existing result set verbatim,
      # only stamping concept annotations onto any citations that both
      # sides know about so the UI can show "(The Lord's Prayer)" etc.
      def self.annotate_only(existing, concept_result)
        concept_by_citation = concept_result.results.index_by { |r| r[:citation] }
        annotated = existing.results.map do |r|
          cr = concept_by_citation[r[:citation]]
          cr ? r.merge(concept_match: cr[:concept_match], concept_role: cr[:concept_role]) : r
        end
        ResultSet.new(
          results: annotated,
          query: existing.query,
          query_type: existing.query_type,
          total_count: existing.total_count,
          facets: existing.facets,
          cross_language_card: existing.cross_language_card,
          redirect: existing.redirect,
          page: existing.page,
          per_page: existing.per_page
        )
      end

      # Heuristic: does the user's query include a verbatim phrase from
      # the top existing result? If yes, FTS has found the source verse
      # and concepts should not displace it. Two paths:
      #   (a) 3+ consecutive query content-words appear in the body
      #       ("grain mustard seed" → "grain OF mustard seed" — short
      #       words are stripped from both sides before comparing).
      #   (b) Very short body (≤ 4 content words) and the whole body
      #       appears as a subsequence in the query. Handles famous
      #       tiny verses like "Jesus wept" (John 11:35) where path
      #       (a) can't fire because the body has < 3 content words.
      def self.phrase_match_in_top?(existing, query)
        top = existing.results.first
        return false unless top && top[:body]
        query_words = content_words(query)
        body_words  = content_words(top[:body])

        # (b) short-body verbatim quote
        if body_words.size > 0 && body_words.size <= 4
          return true if query_words.join(" ").include?(body_words.join(" "))
        end

        # (a) 3+ consecutive query words in body
        return false if query_words.size < 3 || body_words.empty?
        body_joined = body_words.join(" ")
        query_words.each_cons(3).any? { |trio| body_joined.include?(trio.join(" ")) }
      end

      def self.content_words(text)
        text.to_s.downcase.gsub(/[^a-z\s]/, " ").split.reject { |w| w.length < 3 }
      end

      private

      # Substring match on the aliases array. Uses EXISTS over unnest
      # so the GIN index on aliases doesn't actually help here (no
      # tsvector), but the table is small enough that a seq scan is
      # trivial until we grow past a few thousand rows.
      def matching_concepts
        SearchConcept.where(
          "EXISTS (SELECT 1 FROM unnest(aliases) a WHERE ? ILIKE '%' || a || '%')",
          @normalized
        ).to_a
      end

      def fetch_english_wus(cref_ids)
        return [] if cref_ids.empty?
        WorkUnit
          .joins(:canonical_ref, :work)
          .where(canonical_ref_id: cref_ids)
          .where(works: { language: "en" })
          .order("works.title ASC")
          .includes(:canonical_ref, work: :license)
          .group_by(&:canonical_ref_id)
          .values
          .map(&:first)
      end

      def format_result(wu, data)
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
          relevance: data[:relevance],
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key,
          concept_match: data[:concept].name,
          concept_role: data[:role]
        }
      end

      def empty_result
        ResultSet.new(query: @raw_query, query_type: :concept, per_page: @per_page)
      end
    end
  end
end
