module Search
  module Strategies
    class TopicRetrieval
      # Bridges natural-language thematic queries ("anxiety", "war", "the
      # poor") to verses via the topics + topic_verses tables, populated
      # from OpenBible.info Topics and Sefaria Topics.
      #
      # Fires alongside FTS / semantic / person-topic / concept retrieval
      # and is merged into the final ResultSet — does not replace any
      # existing strategy.
      #
      # Why both sources are weighted differently:
      #   Sefaria's topic refs are curator-vetted with a PageRank-style
      #   ordering (`order.pr`); OpenBible's are community-voted. On
      #   contested topics where both have data, Sefaria's ranking is the
      #   stronger signal — see the bias audit (~April 2026) for the
      #   evidence behind the 1.5x weight.

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100

      # Final score = rank_within_topic * source_weight * BOOST_MULTIPLIER.
      # Tuned so the top verse of a single matched topic scores 4.5
      # (Sefaria) or 3.0 (OpenBible) — sits above weak FTS (0.1-0.8) but
      # below alias matches (10.0).
      BOOST_MULTIPLIER = 3.0

      SOURCE_WEIGHTS = {
        "sefaria_topics"   => 1.5,
        "openbible_topics" => 1.0
      }.freeze

      # Per-topic verse cap. Beyond this many we don't really have signal
      # — OpenBible's quality scores degrade past ~20, and we don't want
      # one popular topic to swamp the result set.
      VERSES_PER_TOPIC = 30

      # Topic names that should never trigger a match. Two reasons:
      #  (a) Query meta-vocabulary ("bible", "scripture") — natural-language
      #      queries like "what does the bible say about X" would otherwise
      #      activate a "bible" topic about scripture itself, polluting the
      #      results with 2 Tim 3:16, Heb 4:12, etc.
      #  (b) Biblical person names — PersonTopicSearch already handles these
      #      as persons; matching them as topics double-counts and floods
      #      the result with generic person verses (the OpenBible "jesus"
      #      topic has 692 verses, none specifically tied to the user's
      #      actual topic word).
      MATCH_STOP_NAMES = %w[
        bible the\ bible scripture scriptures the\ scripture
        verse verses passage passages text texts the\ text
        god jesus christ yeshua paul peter john james timothy titus
        barnabas silas luke stephen philip apollos nicodemus lazarus
        martha pilate herod moses abraham david solomon samuel elijah
        elisha isaiah jeremiah ezekiel daniel noah jacob isaac joseph
        joshua gideon samson ruth esther nehemiah ezra job jonah
        adam eve cain abel sarah rebekah rachel leah saul bathsheba
        goliath pharaoh balaam deborah mary naomi
        you us we they me my our your his her him them
        say said tell told ask asked know knew think
        bo
      ].to_set.freeze

      def initialize(query, scope: nil, page: 1, per_page: DEFAULT_LIMIT, query_embedding: nil)
        @raw_query       = query.to_s
        @normalized      = @raw_query.downcase.gsub(/[?!.,;:'"]/, " ").squeeze(" ").strip
        @scope           = scope || {}
        @page            = [page.to_i, 1].max
        @per_page        = [[per_page.to_i, 1].max, MAX_LIMIT].min
        @query_embedding = query_embedding
      end

      def call
        return empty_result if @normalized.blank?

        topics = matching_topics
        return empty_result if topics.empty?

        # Score each verse; when the same canonical_ref is linked by multiple
        # topics (or by both sources), take the highest weighted score.
        best = {}

        topics.group_by(&:source).each do |source, group|
          weight = SOURCE_WEIGHTS[source] || 1.0
          topic_ids = group.map(&:id)

          # max source_rank per topic, used to normalize within topic
          maxes = TopicVerse.where(topic_id: topic_ids)
                            .group(:topic_id)
                            .maximum(:source_rank)

          # take top VERSES_PER_TOPIC per topic
          tvs_by_topic = group.flat_map { |t|
            TopicVerse.where(topic_id: t.id)
                      .order(source_rank: :desc)
                      .limit(VERSES_PER_TOPIC)
                      .pluck(:topic_id, :canonical_ref_id, :source_rank)
          }

          tvs_by_topic.each do |topic_id, cref_id, source_rank|
            tmax = maxes[topic_id].to_f
            next if tmax <= 0
            normalized = source_rank.to_f / tmax
            score = normalized * weight * BOOST_MULTIPLIER

            prior = best[cref_id]
            if prior.nil? || prior[:relevance] < score
              best[cref_id] = {
                canonical_ref_id: cref_id,
                topic_name: group.find { |t| t.id == topic_id }.display_name || group.find { |t| t.id == topic_id }.name,
                source: source,
                relevance: score
              }
            end
          end
        end

        # Centroid expansion was tried (2026-04-29 audit) — for each
        # matched topic, vector-search verses near the avg of the topic's
        # top-K tagged verses' embeddings, add as expansion candidates.
        # Net result was -7 queries (74.70% vs 74.98% baseline). The
        # expansion mostly surfaced semantic neighbors that displaced
        # the topic's existing tagged verses without bringing the
        # missing canonical answers (Lam 3:22 still absent for
        # `faithfulness`, Matt 11:28 still absent for `overwhelmed`).
        # The centroid column + compute task remain for future use, but
        # the expansion call is disabled. See add_centroid_expansion below.

        return empty_result if best.empty?

        english_wus = fetch_english_wus(best.keys)
        results = english_wus.map { |wu|
          format_result(wu, best[wu.canonical_ref_id])
        }.sort_by { |r| -r[:relevance] }.first(@per_page)

        ResultSet.new(
          results: results,
          query: @raw_query,
          query_type: :topic,
          total_count: best.size,
          page: @page,
          per_page: @per_page
        )
      end

      # Merge topic results into an existing ResultSet.
      #
      # Same exact-quote guard as ConceptRetrieval: if the user typed a
      # verbatim 3-word phrase from the top FTS result, don't re-rank —
      # they're looking for the source verse, not paraphrases.
      #
      # Otherwise: prefer the higher of (existing relevance, topic
      # relevance) per citation; topic_match annotations always carry over.
      def self.merge(existing, topic_result, per_page: 25)
        return existing if topic_result.nil? || topic_result.empty?

        if ConceptRetrieval.phrase_match_in_top?(existing, topic_result.query)
          return annotate_only(existing, topic_result)
        end

        # Unconditional pin of existing top-3. Tried "conditional pin"
        # variants (alias_match-only, has_alias-then-pin-top-3) but they
        # consistently regressed paraphrase queries by ~3.5pp on the
        # audit — the unconditional pin protects FTS+alias neighborhoods
        # that conditional variants were missing. Topics provide thematic
        # recall by filling rank 4+; the cost on weak-FTS thematic
        # queries (Jer 6:14 staying at rank 1 for "peace") is smaller
        # than the regression on named-passage neighborhoods.
        pinned = existing.results.first(3)
        pinned_ids = pinned.map { |r| r[:id] }.to_set

        by_citation = {}
        existing.results.each { |r| by_citation[r[:citation]] = r }

        topic_result.results.each do |tr|
          prior = by_citation[tr[:citation]]
          if pinned_ids.include?(tr[:id])
            # Pinned — only annotate, never re-rank.
            by_citation[tr[:citation]] = prior.merge(
              topic_match: tr[:topic_match],
              topic_source: tr[:topic_source]
            )
          elsif prior.nil?
            by_citation[tr[:citation]] = tr
          elsif tr[:relevance] > prior[:relevance]
            by_citation[tr[:citation]] = prior.merge(
              relevance: tr[:relevance],
              topic_match: tr[:topic_match],
              topic_source: tr[:topic_source]
            )
          else
            by_citation[tr[:citation]] = prior.merge(
              topic_match: tr[:topic_match],
              topic_source: tr[:topic_source]
            )
          end
        end

        # Pinned slots emit in original order; everything below sorts by
        # final relevance (FTS+semantic for unmatched, topic-boosted for
        # matched).
        pinned_results = pinned.map { |r| by_citation[r[:citation]] || r }
        rest_results = by_citation.values
                                  .reject { |r| pinned_ids.include?(r[:id]) }
                                  .sort_by { |r| -r[:relevance].to_f }
        merged = (pinned_results + rest_results).first(per_page)

        ResultSet.new(
          results: merged,
          query: existing.query,
          query_type: existing.query_type,
          total_count: existing.total_count + topic_result.total_count,
          facets: existing.facets,
          cross_language_card: existing.cross_language_card,
          redirect: existing.redirect,
          page: existing.page,
          per_page: existing.per_page
        )
      end

      def self.annotate_only(existing, topic_result)
        topic_by_citation = topic_result.results.index_by { |r| r[:citation] }
        annotated = existing.results.map do |r|
          tr = topic_by_citation[r[:citation]]
          tr ? r.merge(topic_match: tr[:topic_match], topic_source: tr[:topic_source]) : r
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

      private

      # Match topics in two layers:
      #  1. **Literal substring match** (fast path): take every 1-N word
      #     contiguous substring of the query and look those up against
      #     the indexed `topics.name` column. Catches exact matches like
      #     "anxiety" → `anxiety` topic for ~zero cost.
      #  2. **Semantic similarity** (recall layer): if a cached query
      #     embedding is available, find topics whose name embedding is
      #     near the query in vector space. Catches morphological /
      #     synonym variants the literal layer misses: "hopeless" →
      #     `hope`, "faithfulness" → `faith`, "afraid" → `fear`, etc.
      MAX_PHRASE_WORDS = 4
      SEMANTIC_TOPIC_LIMIT = 12       # how many semantic topic candidates to fetch
      SEMANTIC_TOPIC_THRESHOLD = 0.55 # cosine similarity floor (Qwen3-Embedding scale)

      # Centroid expansion: for the strongest matched topics, find verses
      # semantically near the topic centroid (avg of top-K tagged verses).
      EXPANSION_TOPIC_LIMIT = 3       # only expand from top-N matched topics
      EXPANSION_VERSES_PER_TOPIC = 10
      EXPANSION_THRESHOLD = 0.5       # cosine sim floor for expansion candidates
      EXPANSION_MULTIPLIER = 2.0      # less than BOOST_MULTIPLIER so tagged verses still win

      def matching_topics
        literal = literal_topic_matches
        semantic = semantic_topic_matches
        # Union by id; literal-matched topics keep their (already-loaded) row.
        seen = literal.map(&:id).to_set
        literal + semantic.reject { |t| seen.include?(t.id) }
      end

      def literal_topic_matches
        phrases = extract_phrases(@normalized, MAX_PHRASE_WORDS)
        return [] if phrases.empty?
        phrases.reject! { |p| MATCH_STOP_NAMES.include?(p) }
        return [] if phrases.empty?
        Topic.where(name: phrases).to_a
      end

      def semantic_topic_matches
        embedding = @query_embedding
        return [] unless embedding
        conn = ApplicationRecord.connection
        vector_literal = "[#{embedding.join(',')}]"
        rows = conn.select_all(<<~SQL)
          SELECT id, source, name, display_name,
                 1 - (name_embedding_qwen3 <=> '#{vector_literal}'::vector) AS similarity
          FROM topics
          WHERE name_embedding_qwen3 IS NOT NULL
          ORDER BY name_embedding_qwen3 <=> '#{vector_literal}'::vector
          LIMIT #{SEMANTIC_TOPIC_LIMIT}
        SQL
        rows.select { |r| r["similarity"].to_f >= SEMANTIC_TOPIC_THRESHOLD }
            .reject { |r| MATCH_STOP_NAMES.include?(r["name"].to_s.downcase) }
            .map { |r|
              t = Topic.new(
                source: r["source"],
                name: r["name"],
                display_name: r["display_name"]
              )
              t.id = r["id"].to_i
              t
            }
      end

      # All 1..n-word contiguous substrings of `text`, lowercased.
      # Tokenization on whitespace gives word-boundary semantics for
      # free — no need for a separate \b...\b regex pass afterward.
      def extract_phrases(text, max_words)
        words = text.split(/\s+/).reject(&:empty?)
        return [] if words.empty?
        out = Set.new
        (1..[max_words, words.length].min).each do |n|
          words.each_cons(n) do |chunk|
            phrase = chunk.join(" ")
            out << phrase if phrase.length >= 2
          end
        end
        out.to_a
      end

      # Find verses semantically near `topic.centroid_embedding_qwen3` and
      # merge them into `best` with score = similarity * source_weight *
      # EXPANSION_MULTIPLIER. This catches verses that aren't explicitly
      # tagged in the topic but live in the same semantic neighborhood as
      # its top tagged verses (data-gap fix).
      def add_centroid_expansion(best, topic)
        weight = SOURCE_WEIGHTS[topic.source] || 1.0
        conn = ApplicationRecord.connection
        rows = conn.select_all(<<~SQL)
          WITH topic_centroid AS (
            SELECT centroid_embedding_qwen3 AS v
            FROM topics
            WHERE id = #{topic.id.to_i}
              AND centroid_embedding_qwen3 IS NOT NULL
          )
          SELECT wu.canonical_ref_id,
                 1 - (e.embedding <=> (SELECT v FROM topic_centroid)) AS similarity
          FROM work_unit_embeddings_qwen3_06b e
          JOIN work_units wu ON wu.id = e.work_unit_id
          JOIN works w ON w.id = wu.work_id
          WHERE w.language = 'en'
            AND EXISTS (SELECT 1 FROM topic_centroid)
          ORDER BY e.embedding <=> (SELECT v FROM topic_centroid)
          LIMIT #{EXPANSION_VERSES_PER_TOPIC}
        SQL

        rows.each do |row|
          similarity = row["similarity"].to_f
          next if similarity < EXPANSION_THRESHOLD
          cref_id = row["canonical_ref_id"].to_i
          score = similarity * weight * EXPANSION_MULTIPLIER

          prior = best[cref_id]
          # Don't downgrade verses already scored higher by tagged-verse logic.
          next if prior && prior[:relevance] >= score
          best[cref_id] = {
            canonical_ref_id: cref_id,
            topic_name: topic.display_name || topic.name,
            source: topic.source,
            relevance: score
          }
        end
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
          topic_match: data[:topic_name],
          topic_source: data[:source]
        }
      end

      def empty_result
        ResultSet.new(query: @raw_query, query_type: :topic, per_page: @per_page)
      end
    end
  end
end
