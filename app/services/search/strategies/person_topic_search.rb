module Search
  module Strategies
    class PersonTopicSearch
      # Handles "What did Jesus say about money?" style queries by:
      # 1. FTS for the topic words across all English scripture
      # 2. Re-ranking with person proximity boosts:
      #    - Verse names the person AND matches topic → highest
      #    - Verse is within ±20 of a verse naming the person → high
      #    - Verse is in the person's primary testament/books → medium
      #    - Verse is in a pericope mentioning the person → medium
      #    - Person is the actor/speaker in the verse → highest

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100
      NEAR_WINDOW = 50  # ±50 ords from a verse mentioning the person
      WIDE_WINDOW = 150 # wider window for weaker boost (covers long speeches)

      # Person → primary books (where their speech/actions are recorded)
      PERSON_BOOKS = {
        "jesus" => %w[matthew mark luke john],
        "christ" => %w[matthew mark luke john],
        "yeshua" => %w[matthew mark luke john],
        "paul" => %w[acts romans 1-corinthians 2-corinthians galatians ephesians philippians colossians 1-thessalonians 2-thessalonians 1-timothy 2-timothy titus philemon],
        "peter" => %w[matthew mark luke john acts 1-peter 2-peter],
        "moses" => %w[exodus leviticus numbers deuteronomy],
        "david" => %w[1-samuel 2-samuel psalms 1-chronicles],
        "solomon" => %w[1-kings 2-chronicles proverbs ecclesiastes song-of-solomon],
        "abraham" => %w[genesis],
        "elijah" => %w[1-kings 2-kings],
        "isaiah" => %w[isaiah],
        "jeremiah" => %w[jeremiah lamentations],
        "job" => %w[job],
        "daniel" => %w[daniel],
        "john" => %w[john 1-john 2-john 3-john revelation],
        "james" => %w[james],
      }.freeze

      SPEECH_VERBS = /\b(said|answered|spoke|told|asked|taught|commanded|replied|cried|declared|proclaimed|called|instructed|warned|rebuked|blessed|prayed)\b/i

      def initialize(person, topic_words, raw_query:, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @person = person.downcase
        @topic_words = topic_words
        @raw_query = raw_query
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        return empty_result if @topic_words.empty?

        conn = ApplicationRecord.connection
        topic_query = @topic_words.join(" ")
        topic_tsq = "websearch_to_tsquery('scriptorium_english', #{conn.quote(topic_query)})"

        # Also build synonym-expanded topic query
        expanded_topic = conn.select_value("SELECT expand_bible_synonyms(#{conn.quote(topic_query)})")
        expanded_tsq = if expanded_topic && expanded_topic != topic_query
          "websearch_to_tsquery('scriptorium_english', #{conn.quote(expanded_topic)})"
        end
        combined_tsq = expanded_tsq ? "(#{topic_tsq} || #{expanded_tsq})" : topic_tsq

        # Pre-compute person context
        person_ords = precompute_person_ords(conn)
        pericope_ref_ids = precompute_pericope_refs(conn)
        primary_books = PERSON_BOOKS[@person] || []

        # TWO-PASS APPROACH:
        # Pass 1: Find topic matches WITHIN the person's context (primary
        #   books + near person mentions + pericopes). This is the focused set.
        # Pass 2: Find topic matches globally for supplementary results.
        # Merge with Pass 1 results on top.

        # Build the person-context scope: primary books for this person
        book_cw_ids = CanonicalWork.where(book_key: primary_books).pluck(:id)

        focused_results = []
        if book_cw_ids.any?
          focused = WorkUnit
            .joins(:canonical_ref, :work)
            .joins("JOIN canonical_works ON canonical_works.id = canonical_refs.canonical_work_id")
            .where("work_units.body_tsvector @@ #{combined_tsq}")
            .where(works: { language: "en" })
            .where("canonical_refs.canonical_work_id IN (?)", book_cw_ids)
            .includes(:canonical_ref, work: :license)

          focused = apply_scope(focused)

          focused_results = focused
            .select(
              "work_units.*",
              "ts_rank(work_units.body_tsvector, #{combined_tsq}) AS topic_rank",
              "canonical_refs.ord AS cref_ord",
              "canonical_works.book_key AS book_key",
              "canonical_refs.canonical_work_id AS cw_id"
            )
            .order(Arel.sql("topic_rank DESC"))
            .limit(100)
            .to_a
        end

        # Pass 2: Global topic matches (for supplementary results from other books)
        global = WorkUnit
          .joins(:canonical_ref, :work)
          .joins("JOIN canonical_works ON canonical_works.id = canonical_refs.canonical_work_id")
          .where("work_units.body_tsvector @@ #{combined_tsq}")
          .where(works: { language: "en" })
          .includes(:canonical_ref, work: :license)
        global = apply_scope(global)
        total = global.count

        global_results = global
          .select(
            "work_units.*",
            "ts_rank(work_units.body_tsvector, #{combined_tsq}) AS topic_rank",
            "canonical_refs.ord AS cref_ord",
            "canonical_works.book_key AS book_key",
            "canonical_refs.canonical_work_id AS cw_id"
          )
          .order(Arel.sql("topic_rank DESC"))
          .limit(50)
          .to_a

        # Merge and deduplicate — focused first, then global
        seen_ids = Set.new
        all_candidates = []
        (focused_results + global_results).each do |wu|
          next if seen_ids.include?(wu.id)
          seen_ids << wu.id
          all_candidates << wu
        end

        return empty_result if all_candidates.empty?

        # Score each candidate with person-context boosts
        scored = all_candidates.map { |wu|
          score = wu.topic_rank.to_f
          body = wu.body.to_s.downcase
          ord = wu.cref_ord.to_i
          cw_id = wu.cw_id.to_i
          book = wu.book_key

          # The focused set already filters to the person's primary books,
          # so topic relevance is the main ranking signal. Apply moderate
          # contextual boosts — these are tie-breakers, not dominant factors.

          # Boost 1: Person is the speaker/actor in this verse
          if body.include?(@person) && person_is_actor?(body)
            score *= 2.0
          end

          # Boost 2: Verse is near a verse naming the person
          min_dist = person_ords[cw_id]&.map { |o| (ord - o).abs }&.min
          if min_dist
            if min_dist == 0  # person named in this verse
              score *= 1.3
            elsif min_dist <= NEAR_WINDOW
              score *= 1.2
            elsif min_dist <= WIDE_WINDOW
              score *= 1.1
            end
          end

          # Boost 3: In a pericope mentioning the person
          if pericope_ref_ids.include?(wu.canonical_ref_id)
            score *= 1.3
          end

          format_result(wu, score)
        }

        # Deduplicate by citation
        best = {}
        scored.each do |r|
          key = r[:citation]
          if best[key].nil? || r[:relevance] > best[key][:relevance]
            best[key] = r
          end
        end

        results = best.values
                    .sort_by { |r| -r[:relevance] }
                    .first(@per_page)

        ResultSet.new(
          results: results,
          query: @raw_query,
          query_type: :person_topic,
          total_count: total,
          page: @page,
          per_page: @per_page
        )
      end

      private

      def precompute_person_ords(conn)
        rows = conn.select_all(<<~SQL)
          SELECT DISTINCT cr.canonical_work_id, cr.ord
          FROM work_units wu
          JOIN canonical_refs cr ON cr.id = wu.canonical_ref_id
          JOIN works w ON w.id = wu.work_id
          WHERE w.language = 'en'
            AND wu.body ILIKE #{conn.quote("%#{@person}%")}
        SQL

        by_cw = Hash.new { |h, k| h[k] = [] }
        rows.each { |r| by_cw[r["canonical_work_id"].to_i] << r["ord"].to_i }
        by_cw
      end

      def precompute_pericope_refs(conn)
        return Set.new unless Pericope.table_exists?

        ref_ids = conn.select_values(<<~SQL)
          SELECT cr.id
          FROM pericopes p
          JOIN canonical_refs cr
            ON cr.canonical_work_id = p.canonical_work_id
            AND cr.ord <@ p.canonical_range
          WHERE p.name ILIKE #{conn.quote("%#{@person}%")}
          LIMIT 5000
        SQL
        ref_ids.map(&:to_i).to_set
      end

      def person_is_actor?(body)
        escaped = Regexp.escape(@person)
        body.match?(/\b#{escaped}\b.{0,40}#{SPEECH_VERBS}/i) ||
          body.match?(/#{SPEECH_VERBS}.{0,20}\b#{escaped}\b/i)
      end

      def apply_scope(base)
        if @scope.is_a?(Hash)
          base = base.where(works: { slug: @scope[:work] }) if @scope[:work].present?
          base = base.where(works: { work_type: @scope[:work_types] }) if @scope[:work_types].is_a?(Array)
          if @scope[:languages].is_a?(Array)
            base = base.where(works: { language: @scope[:languages] })
          end
        end
        base
      end

      def format_result(wu, score)
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
          relevance: score,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key
        }
      end

      def empty_result
        ResultSet.new(query: @raw_query, query_type: :person_topic)
      end
    end
  end
end
