module Search
  module Strategies
    class PersonTopicSearch
      # Handles "What did Jesus say about money?" queries using Macula
      # participant_references to find verses where the named person is
      # the grammatical subject or semantic agent, then ranking by topic
      # relevance within that set + expanded nearby verses.

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100
      SPEECH_WINDOW = 100  # ords to expand around agent verses (covers long speeches)

      # Person name → primary books (fallback when Macula data is sparse)
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
        "ruth" => %w[ruth],
        "esther" => %w[esther],
        "jonah" => %w[jonah],
        "samuel" => %w[1-samuel 2-samuel],
        "god" => %w[genesis exodus leviticus numbers deuteronomy joshua judges 1-samuel 2-samuel 1-kings 2-kings isaiah jeremiah ezekiel hosea joel amos obadiah jonah micah nahum habakkuk zephaniah haggai zechariah malachi job psalms],
        "naomi" => %w[ruth],
        "goliath" => %w[1-samuel],
      }.freeze

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

        # Build a broad topic tsquery that handles stemming gaps.
        # "prayer" stems to 'prayer' but "pray" stems to 'pray' — they
        # have different lexemes in English Snowball. Generate both the
        # original word AND likely root forms (strip common suffixes).
        topic_tsq = "websearch_to_tsquery('scriptorium_english', #{conn.quote(topic_query)})"
        word_tsqs = []

        # For each topic word, also add root forms that strip common
        # English suffixes (prayer→pray, forgiveness→forgive, etc.)
        all_forms = @topic_words.dup
        @topic_words.each { |w| all_forms.concat(root_forms(w)) }
        all_forms.uniq.each do |w|
          word_tsqs << "plainto_tsquery('scriptorium_english', #{conn.quote(w)})"
        end

        # Synonym expansion
        expanded = conn.select_value("SELECT expand_bible_synonyms(#{conn.quote(topic_query)})")
        if expanded && expanded != topic_query
          word_tsqs << "websearch_to_tsquery('scriptorium_english', #{conn.quote(expanded)})"
        end

        combined_tsq = "(" + ([topic_tsq] + word_tsqs).join(" || ") + ")"

        # Step 1: Find canonical_refs where person is subject/agent (Macula data)
        agent_cref_ids = find_agent_crefs
        agent_cref_set = agent_cref_ids.to_set

        # Step 2: Expand to nearby verses (covers speech blocks)
        expanded_cref_ids = expand_crefs(agent_cref_ids, conn)

        # Step 3: Also get primary book cref_ids as fallback
        primary_books = PERSON_BOOKS[@person] || []
        book_cw_ids = CanonicalWork.where(book_key: primary_books).pluck(:id) if primary_books.any?

        # Pericope context: find canonical_ref_ids in pericopes matching
        # the topic. Two levels:
        # 1. topic_pericope: pericope name matches topic (3x boost)
        # 2. dual_pericope: pericope name matches BOTH person AND topic
        #    (6x boost) — "David Slays Goliath" for query about David+Goliath
        # Must be computed before any tier scoring runs — score_result reads
        # these sets to apply the boost.
        topic_pericope_cref_ids = find_topic_pericope_cref_ids(conn, book_cw_ids)
        @topic_pericope_set = topic_pericope_cref_ids.to_set
        dual_pericope_cref_ids = find_dual_pericope_cref_ids(conn)
        @dual_pericope_set = dual_pericope_cref_ids.to_set

        # Step 4: Search for topic in four tiers, merge results
        results = []

        # Tier A: Topic matches in agent verses (person is subject/agent HERE)
        if agent_cref_ids.any?
          tier_a = topic_search_in_crefs(agent_cref_ids, combined_tsq, limit: 50)
          results.concat(tier_a.map { |wu| score_result(wu, :agent) })
        end

        # Tier B: Topic matches in expanded window (person speaks nearby)
        if expanded_cref_ids.any?
          tier_b = topic_search_in_crefs(expanded_cref_ids, combined_tsq, limit: 80)
          results.concat(tier_b.map { |wu|
            tier = agent_cref_set.include?(wu.canonical_ref_id) ? :agent : :nearby
            score_result(wu, tier)
          })
        end

        # Tier C: Topic matches in primary books (fallback)
        if book_cw_ids&.any?
          tier_c = WorkUnit
            .joins(:canonical_ref, :work)
            .where("work_units.body_tsvector @@ #{combined_tsq}")
            .where(works: { language: "en" })
            .where("canonical_refs.canonical_work_id IN (?)", book_cw_ids)
            .select("work_units.*",
              "ts_rank(work_units.body_tsvector, #{combined_tsq}) AS topic_rank")
            .order(Arel.sql("topic_rank DESC"))
            .limit(200)
            .includes(:canonical_ref, work: :license)
          results.concat(tier_c.map { |wu|
            tier = if agent_cref_set.include?(wu.canonical_ref_id)
              :agent
            elsif expanded_cref_ids.to_set.include?(wu.canonical_ref_id)
              :nearby
            else
              :book
            end
            score_result(wu, tier)
          })
        end

        # Conceptual fallback: add verses from topic-matching pericopes
        # that weren't found by keyword search. These have no FTS match
        # but are in a pericope whose name matches the topic concept.
        if topic_pericope_cref_ids.any?
          # Find verses in topic pericopes that aren't already in results
          existing_cref_ids = results.map { |r| r[:canonical_ref_id] }.compact.to_set
          new_cref_ids = topic_pericope_cref_ids.reject { |id| existing_cref_ids.include?(id) }
          if new_cref_ids.any?
            conceptual = WorkUnit
              .joins(:canonical_ref, :work)
              .where(canonical_ref_id: new_cref_ids.first(500))
              .where(works: { language: "en" })
              .select("work_units.*", "0.01 AS topic_rank")
              .limit(50)
              .includes(:canonical_ref, work: :license)
            results.concat(conceptual.map { |wu| score_result(wu, :pericope) })
          end
        end

        return empty_result if results.empty?

        # Deduplicate by citation, keeping highest score
        best = {}
        results.each do |r|
          key = r[:citation]
          if best[key].nil? || r[:relevance] > best[key][:relevance]
            best[key] = r
          end
        end

        sorted = best.values.sort_by { |r| -r[:relevance] }.first(@per_page)

        # Count total from broadest tier
        total = if book_cw_ids&.any?
          WorkUnit.joins(:canonical_ref, :work)
            .where("work_units.body_tsvector @@ #{combined_tsq}")
            .where(works: { language: "en" })
            .where("canonical_refs.canonical_work_id IN (?)", book_cw_ids)
            .count
        else
          results.size
        end

        ResultSet.new(
          results: sorted,
          query: @raw_query,
          query_type: :person_topic,
          total_count: total,
          page: @page,
          per_page: @per_page
        )
      end

      private

      # Find canonical_ref_ids where the person is subject or agent
      # using Macula participant_references.
      def find_agent_crefs
        # Find words matching the person name via lemma gloss
        person_word_ids = Word.joins(:lemma)
          .where("lemmas.primary_gloss ILIKE ?", "#{@person}%")
          .where(lemmas: { language: %w[he hbo arc el-koine grc] })
          .pluck(:id)

        # Also try surface-form matching for common variants
        surface_patterns = person_surface_patterns
        if surface_patterns.any?
          surface_ids = Word.where(
            surface_patterns.map { "surface LIKE ?" }.join(" OR "),
            *surface_patterns
          ).pluck(:id)
          person_word_ids = (person_word_ids + surface_ids).uniq
        end

        return [] if person_word_ids.empty?

        # Find work_units where this person is subject/agent
        wu_ids = ParticipantReference
          .where(referent_word_id: person_word_ids)
          .where(ref_type: %w[subject frame_a0])
          .distinct
          .pluck(:work_unit_id)

        return [] if wu_ids.empty?

        WorkUnit.where(id: wu_ids).pluck(:canonical_ref_id).uniq
      end

      # Surface patterns for names that don't match via gloss
      def person_surface_patterns
        case @person
        when "jesus", "yeshua" then ["Ἰησοῦ%"]
        when "christ" then ["Χριστ%"]
        when "moses" then ["Μω%σ%", "מֹשֶׁ%", "מֹשֶׁ%", "משׁה%"]
        when "david" then ["Δαυ%δ%", "דָּוִ%", "דָוִ%", "דּוד%"]
        when "paul" then ["Παῦλ%", "Σαῦλ%"]
        when "peter" then ["Πέτρ%", "Σίμων%"]
        when "solomon" then ["Σολομ%", "שְׁלֹמֹ%", "שׁלמה%"]
        when "abraham" then ["Ἀβρα%μ%", "אַבְרָ%", "אברהם%"]
        when "elijah" then ["Ἠλί%", "אֵלִיָּ%"]
        when "isaiah" then ["Ἠσαΐ%", "יְשַׁעְיָ%"]
        when "jeremiah" then ["Ἰερεμ%", "יִרְמְיָ%"]
        when "job" then ["אִיּ%"]
        when "daniel" then ["Δανι%λ%", "דָּנִיֵּ%"]
        when "ruth" then ["Ῥούθ%", "רוּת%"]
        when "jonah" then ["Ἰωνᾶ%", "יוֹנָ%"]
        when "god" then ["אֱלֹהִ%", "אלהים%", "יהוה%", "Θε%"]
        when "naomi" then ["נָעֳמִ%"]
        when "samuel" then ["שְׁמוּאֵ%"]
        when "esther" then ["אֶסְתֵּ%"]
        else []
        end
      end

      # Expand canonical_ref_ids by ±SPEECH_WINDOW within each canonical_work
      def expand_crefs(cref_ids, conn)
        return [] if cref_ids.empty?

        # Get (canonical_work_id, ord) for each cref
        locations = CanonicalRef.where(id: cref_ids).pluck(:canonical_work_id, :ord)
        return [] if locations.empty?

        # Group by canonical_work and build ranges
        by_cw = Hash.new { |h, k| h[k] = [] }
        locations.each { |cw_id, ord| by_cw[cw_id] << ord }

        conditions = by_cw.map { |cw_id, ords|
          min_ord = ords.min - SPEECH_WINDOW
          max_ord = ords.max + SPEECH_WINDOW
          "(canonical_work_id = #{cw_id.to_i} AND ord BETWEEN #{min_ord} AND #{max_ord})"
        }

        conn.select_values(
          "SELECT id FROM canonical_refs WHERE #{conditions.join(' OR ')} LIMIT 20000"
        ).map(&:to_i)
      end

      def topic_search_in_crefs(cref_ids, tsq, limit:)
        # Batch in chunks to avoid huge IN clauses
        cref_ids = cref_ids.first(10000)
        WorkUnit
          .joins(:canonical_ref, :work)
          .where(canonical_ref_id: cref_ids)
          .where(works: { language: "en" })
          .where("work_units.body_tsvector @@ #{tsq}")
          .select("work_units.*",
            "ts_rank(work_units.body_tsvector, #{tsq}) AS topic_rank")
          .order(Arel.sql("topic_rank DESC"))
          .limit(limit)
          .includes(:canonical_ref, work: :license)
      end

      # Find verses within pericopes whose NAMES match the topic words.
      # This bridges the keyword→concept gap: "cross" finds "The
      # Crucifixion" pericope, "prayer" finds "The Lord's Prayer", etc.
      # Filters to the person's primary books to keep results relevant.
      def find_topic_pericope_cref_ids(conn, book_cw_ids)
        return [] unless Pericope.table_exists?

        # Search pericope names for topic words (and root forms)
        all_terms = @topic_words.dup
        @topic_words.each { |w| all_terms.concat(root_forms(w)) }
        all_terms.uniq!

        pericope_conditions = all_terms.map { |t|
          "p.name ILIKE #{conn.quote("%#{ApplicationRecord.sanitize_sql_like(t)}%")}"
        }
        return [] if pericope_conditions.empty?

        # Optionally filter to person's books
        cw_filter = if book_cw_ids&.any?
          "AND p.canonical_work_id IN (#{book_cw_ids.join(",")})"
        else
          ""
        end

        # Find canonical_ref_ids within matching pericopes
        cref_ids = conn.select_values(<<~SQL)
          SELECT DISTINCT cr.id
          FROM pericopes p
          JOIN canonical_refs cr
            ON cr.canonical_work_id = p.canonical_work_id
            AND cr.ord <@ p.canonical_range
          WHERE (#{pericope_conditions.join(" OR ")})
            #{cw_filter}
          LIMIT 2000
        SQL
        return [] if cref_ids.empty?

        cref_ids.map(&:to_i)
      end

      def score_result(wu, tier)
        base = wu.respond_to?(:topic_rank) ? wu.topic_rank.to_f : 0.01

        score = case tier
        when :agent          then base * 10.0   # person is subject/agent in this verse
        when :nearby         then base * 5.0    # within speech window of agent verse
        when :pericope       then base * 2.0    # conceptual match (pericope name matches topic)
        when :book           then base * 1.0    # in person's primary book, no proximity
        else base
        end

        # Pericope name boost: verses in pericopes matching the topic
        # get boosted. Dual match (person + topic both in pericope name)
        # gets a stronger boost — "David Slays Goliath" for david+goliath.
        if @dual_pericope_set&.include?(wu.canonical_ref_id)
          score *= 6.0
        elsif @topic_pericope_set&.include?(wu.canonical_ref_id)
          score *= 3.0
        end

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

      # Find canonical_ref_ids in pericopes whose names match BOTH
      # the person AND the topic. "David Slays Goliath" matches both
      # "david" and "goliath" — very strong signal.
      def find_dual_pericope_cref_ids(conn)
        return [] unless Pericope.table_exists?

        all_terms = @topic_words.dup
        @topic_words.each { |w| all_terms.concat(root_forms(w)) }
        all_terms.uniq!

        topic_conds = all_terms.map { |t|
          "p.name ILIKE #{conn.quote("%#{ApplicationRecord.sanitize_sql_like(t)}%")}"
        }
        person_cond = "p.name ILIKE #{conn.quote("%#{ApplicationRecord.sanitize_sql_like(@person)}%")}"

        conn.select_values(<<~SQL).map(&:to_i)
          SELECT DISTINCT cr.id
          FROM pericopes p
          JOIN canonical_refs cr
            ON cr.canonical_work_id = p.canonical_work_id
            AND cr.ord <@ p.canonical_range
          WHERE #{person_cond}
            AND (#{topic_conds.join(" OR ")})
          LIMIT 2000
        SQL
      end

      def dedup_by_citation(results)
        best = {}
        results.each do |r|
          key = r[:citation]
          if best[key].nil? || r[:relevance] > best[key][:relevance]
            best[key] = r
          end
        end
        best.values.sort_by { |r| -r[:relevance] }
      end

      # Generate likely root forms for a word to handle noun/verb stem
      # mismatches. "prayer" → ["pray"], "forgiveness" → ["forgive"],
      # "suffering" → ["suffer"].
      def root_forms(word)
        roots = []
        w = word.downcase
        roots << w.sub(/er$/, "")           if w.end_with?("er") && w.length > 4    # prayer→pray
        roots << w.sub(/ness$/, "")         if w.end_with?("ness") && w.length > 6  # forgiveness→forgive (wait, "eness")
        roots << w.sub(/eness$/, "e")       if w.end_with?("eness")                 # forgiveness→forgive
        roots << w.sub(/ment$/, "")         if w.end_with?("ment") && w.length > 6  # atonement→atone
        roots << w.sub(/tion$/, "")         if w.end_with?("tion") && w.length > 6  # salvation→salva...
        roots << w.sub(/tion$/, "te")       if w.end_with?("tion") && w.length > 6  # creation→create
        roots << w.sub(/ation$/, "e")       if w.end_with?("ation") && w.length > 7 # creation→create
        roots << w.sub(/ing$/, "")          if w.end_with?("ing") && w.length > 5   # suffering→suffer
        roots << w.sub(/ing$/, "e")         if w.end_with?("ing") && w.length > 5   # forgiving→forgive
        roots << w.sub(/ance$/, "")         if w.end_with?("ance") && w.length > 6  # repentance→repent
        roots << w.sub(/ence$/, "")         if w.end_with?("ence") && w.length > 6
        roots << w.sub(/ful$/, "")          if w.end_with?("ful") && w.length > 5
        roots << w.sub(/ous$/, "")          if w.end_with?("ous") && w.length > 5
        roots << w.sub(/ive$/, "e")         if w.end_with?("ive") && w.length > 5   # forgive stays
        # Also try adding common suffixes to find noun from verb
        roots << "#{w}er"                   if w.length >= 3 && w.length <= 8        # pray→prayer
        roots << "#{w}ing"                  if w.length >= 3 && w.length <= 8        # pray→praying
        roots.reject { |r| r.length < 3 || r == w }.uniq
      end

      def empty_result
        ResultSet.new(query: @raw_query, query_type: :person_topic)
      end
    end
  end
end
