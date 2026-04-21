module Search
  module Strategies
    class SemanticMerge
      # Merges semantic (embedding) search results into an existing FTS
      # result set. Degrades gracefully: if no embeddings are loaded or
      # the model isn't available, returns the original FTS results unchanged.
      #
      # The hybrid score formula:
      #   score = α × fts_relevance + β × cosine_similarity
      #
      # α and β are tuned so FTS exact matches always rank above pure
      # semantic matches, but semantic matches fill gaps where keywords fail.

      FTS_WEIGHT = 0.7    # α (reverted to 70.1% baseline)
      SEM_WEIGHT = 0.3    # β
      SEM_LIMIT  = 80     # max embedding candidates to fetch
      MIN_SIMILARITY = 0.3 # below this, semantic results are noise
      LANG_BOOST = 1.4    # multiply score for results matching query language
      TESTAMENT_BOOST = 1.5  # multiply score for results from the right testament
      PERSON_SPEAKER_BOOST = 2.5  # person is the speaker/actor
      PERSON_MENTION_BOOST = 1.3  # person mentioned
      PERSON_PERICOPE_BOOST = 1.4 # verse is in a pericope featuring this person
      PERICOPE_TOPIC_BOOST = 2.0  # verse is in a pericope matching the query topic

      # Common question/filler words that add noise to embedding queries.
      # Stripping these before encoding focuses the vector on content words.
      STOP_WORDS = %w[
        what where when who why how does did do is are was were
        the a an of in to for and or but with about from by
        that this these those it its they them their
        can could should would will shall may might
        bible say says said tell tells told teach teaches
        verse verses passage passages scripture scriptures
        talk talks about regarding concerning
      ].to_set.freeze

      def initialize(query, fts_result, scope: nil, page: 1, per_page: 25)
        @query = query
        @fts_result = fts_result
        @scope = scope
        @page = page
        @per_page = per_page
      end

      def call
        # When FTS already has high-confidence results (alias matches or
        # phrase-bonus hits), semantic search only adds noise. Skip the
        # expensive embedding encode + vector search entirely.
        #
        # FTS relevance = ts_rank * xref_boost * phrase_bonus. Typical
        # ts_rank is 0.01-0.1, so a 10x phrase bonus gives ~0.1-1.0.
        # Check if any result has an alias match, or if the top result's
        # relevance is significantly above the non-boosted baseline.
        fts_results = @fts_result.results
        has_alias = fts_results.any? { |r| r[:alias_match] }
        max_fts = fts_results.map { |r| r[:relevance].to_f }.max || 0
        min_fts = fts_results.map { |r| r[:relevance].to_f }.min || 0
        # If the max is 5x+ above the min, a phrase bonus fired
        phrase_bonus_detected = fts_results.size > 1 && max_fts > min_fts * 5
        if has_alias || (phrase_bonus_detected && max_fts > 0.05)
          return @fts_result
        end

        embedding = encode_query
        return @fts_result unless embedding

        semantic_results = find_semantic_matches(embedding)

        # For person-topic queries, also run a focused embedding search
        # using just the content words (person + topic) to catch verses
        # that the full question embedding might miss.
        if person_topic_query?
          focused = encode_focused_query
          if focused
            focused_results = find_semantic_matches(focused)
            semantic_results = merge_candidate_lists(semantic_results, focused_results)
          end
        end

        return @fts_result if semantic_results.empty?

        merge_results(semantic_results)
      end

      private

      # Encode the query string into a 768-dim vector.
      # Uses a Python subprocess with the trained model.
      # Returns nil if the model isn't available.
      def encode_query
        model_path = Rails.root.join("tmp/embedding_model")
        return nil unless model_path.exist?

        # For question-style queries, encode the full query — LaBSE handles
        # natural language well and short keyword fragments lose context.
        # For keyword queries, strip filler to sharpen the embedding.
        if question_query?
          text = @query
        else
          words = @query.gsub(/[?!.,;:]/, "").split
          content = words.reject { |w| STOP_WORDS.include?(w.downcase) }
          text = content.size >= 2 ? content.join(" ") : @query
        end

        EmbeddingEncoder.instance.encode(text)
      rescue => e
        Rails.logger.warn("[SemanticMerge] encode failed: #{e.message}")
        nil
      end

      # For person-topic queries ("What did Jesus teach about forgiveness?"),
      # build a focused embedding from just the content words. This
      # sharpens the vector toward the actual topic rather than diluting
      # it with question scaffolding.
      def encode_focused_query
        words = @query.gsub(/[?!.,;:]/, "").split
        content = words.reject { |w| STOP_WORDS.include?(w.downcase) }
        return nil if content.size < 2

        text = content.join(" ")
        return nil if text == @query # already identical

        EmbeddingEncoder.instance.encode(text)
      rescue => e
        Rails.logger.warn("[SemanticMerge] focused encode failed: #{e.message}")
        nil
      end

      # Merge two lists of semantic candidates, keeping the higher
      # similarity score when both contain the same work_unit.
      def merge_candidate_lists(primary, secondary)
        by_id = {}
        primary.each { |r| by_id[r[:id]] = r }
        secondary.each do |r|
          existing = by_id[r[:id]]
          if existing
            # Keep whichever has the higher similarity
            by_id[r[:id]] = r if r[:relevance] > existing[:relevance]
          else
            by_id[r[:id]] = r
          end
        end
        by_id.values
      end

      def find_semantic_matches(embedding)
        conn = ApplicationRecord.connection
        vector_literal = "[#{embedding.join(',')}]"

        # Semantic search uses relaxed scope: keep work_type filter but
        # drop language filter — embeddings are cross-lingual by design
        scope_sql = build_scope_sql(conn, skip_language: true)

        rows = conn.select_all(<<~SQL)
          SELECT wu.id,
                 wu.body,
                 wu.canonical_ref_id,
                 w.slug AS work_slug,
                 w.title AS work_title,
                 w.language,
                 cr.sbl_citation AS citation,
                 cr.hierarchy,
                 cr.ord,
                 l.name AS license,
                 cw.book_key,
                 1 - (wu.body_embedding <=> '#{vector_literal}'::vector) AS similarity
          FROM work_units wu
          JOIN works w ON w.id = wu.work_id
          JOIN canonical_refs cr ON cr.id = wu.canonical_ref_id
          JOIN canonical_works cw ON cw.id = cr.canonical_work_id
          JOIN licenses l ON l.id = w.license_id
          WHERE wu.body_embedding IS NOT NULL
            #{scope_sql}
          ORDER BY wu.body_embedding <=> '#{vector_literal}'::vector
          LIMIT #{SEM_LIMIT}
        SQL

        rows.select { |r| r["similarity"].to_f >= MIN_SIMILARITY }.map { |r|
          {
            id: r["id"].to_i,
            work_slug: r["work_slug"],
            work_title: r["work_title"],
            language: r["language"],
            canonical_ref_id: r["canonical_ref_id"].to_i,
            citation: r["citation"],
            hierarchy: r["hierarchy"],
            body: r["body"],
            headline: r["body"],
            relevance: r["similarity"].to_f,
            license: r["license"],
            book_slug: r["book_key"],
            semantic: true
          }
        }
      end

      def merge_results(semantic_results)
        fts_results = @fts_result.results

        # Adaptive weights: when FTS returns few results, lean harder on semantic
        fts_alpha, sem_beta = adaptive_weights(fts_results)

        # Normalize FTS scores to 0..1 using a fixed ceiling rather than
        # max-in-result-set. ts_rank rarely exceeds 0.5 for multi-word queries;
        # phrase-bonus pushes the best hits to ~5. Using a fixed ceiling means
        # weak FTS hits (0.05) stay weak (0.01) instead of being inflated to 1.0.
        fts_ceiling = [fts_results.map { |r| r[:relevance].to_f }.max || 1.0, 1.0].max
        # For very strong FTS results (phrase matches with bonus), cap at their actual max
        # For weak FTS results, the ceiling of 1.0 keeps them proportionally low

        # Score all results (FTS + semantic, deduplicated by work_unit id)
        scored = {}

        fts_results.each do |r|
          scored[r[:id]] = {
            result: r,
            fts_score: r[:relevance].to_f / fts_ceiling,
            sem_score: 0.0
          }
        end

        semantic_results.each do |r|
          if scored[r[:id]]
            scored[r[:id]][:sem_score] = r[:relevance]
          else
            scored[r[:id]] = {
              result: r,
              fts_score: 0.0,
              sem_score: r[:relevance]
            }
          end
        end

        # Compute hybrid score and sort, boosting results that match
        # the query language, testament/person context, and pericope topics
        query_langs = detect_query_languages
        boosted_books = detect_testament_books
        person_name = detect_person_name
        topic_words = extract_topic_words
        pericope_ords = topic_words.any? ? find_pericope_ords(topic_words, person_name) : {}
        person_context_ids = person_name ? find_person_context_ids(scored, person_name) : Set.new

        merged = scored.values.map { |s|
          hybrid = fts_alpha * s[:fts_score] + sem_beta * s[:sem_score]
          lang = s[:result][:language]
          hybrid *= LANG_BOOST if query_langs.include?(lang)
          book = s[:result][:book_slug]
          hybrid *= TESTAMENT_BOOST if boosted_books && boosted_books.include?(book)

          # Person boosting: check if the named person is acting/speaking
          if person_name
            body = s[:result][:body].to_s.downcase
            if body.include?(person_name) && person_is_actor?(body, person_name)
              hybrid *= PERSON_SPEAKER_BOOST
            elsif body.include?(person_name)
              hybrid *= PERSON_MENTION_BOOST
            elsif person_context_ids.include?(s[:result][:id])
              # Person appears in nearby verses (same pericope context)
              hybrid *= PERSON_PERICOPE_BOOST
            end
          end

          # Pericope topic boosting: if the verse falls within a pericope
          # whose name matches the query topic, boost it
          ord = s[:result][:hierarchy]
          cref_id = s[:result][:canonical_ref_id]
          if pericope_ords[:ref_ids]&.include?(cref_id)
            hybrid *= PERICOPE_TOPIC_BOOST
          end

          s[:result].merge(relevance: hybrid)
        }.sort_by { |r| -r[:relevance] }

        # Deduplicate by passage identity — keep the best work_unit per
        # unique citation. When multiple translations of the same verse
        # appear, prefer the one whose body text best matches the query
        # (so KJV "Thou shalt not kill" beats BSB "You shall not murder"
        # when the user searched "Thou shalt not kill").
        query_lower = @query.downcase.gsub(/[^a-z0-9\s]/, "")
        best_per_citation = {}
        merged.each do |r|
          cite = r[:citation]
          next unless cite
          body_lower = r[:body].to_s.downcase.gsub(/[^a-z0-9\s]/, "")
          phrase_match = body_lower.include?(query_lower) ? 1 : 0
          existing = best_per_citation[cite]
          if existing.nil? ||
             phrase_match > existing[:phrase_match] ||
             (phrase_match == existing[:phrase_match] && r[:relevance] > existing[:result][:relevance])
            # Preserve alias_match flag across dedup: if any version of
            # this citation had an alias match, keep it even when a
            # higher-scoring translation replaces the result.
            if existing&.dig(:result, :alias_match) && !r[:alias_match]
              r = r.merge(alias_match: true)
            end
            best_per_citation[cite] = { result: r, phrase_match: phrase_match }
          end
        end
        deduped = best_per_citation.values
                    .sort_by { |v| -v[:result][:relevance] }
                    .map { |v| v[:result] }

        # Pin alias matches and strong phrase matches at the top.
        # These are high-confidence results (user typed the exact text
        # or a known passage name) that should never be outranked by
        # semantic similarity.
        pinned, rest = deduped.partition { |r|
          r[:alias_match] || r[:relevance].to_f > 5.0
        }
        deduped = pinned + rest

        # Paginate
        page_results = deduped.first(@per_page)

        ResultSet.new(
          results: page_results,
          query: @fts_result.query,
          query_type: @fts_result.query_type,
          total_count: [@fts_result.total_count, merged.size].max,
          facets: @fts_result.facets,
          cross_language_card: @fts_result.cross_language_card,
          page: @page,
          per_page: @per_page
        )
      end

      # Adjust FTS/semantic weights based on query shape and FTS quality.
      # Question-style queries lean heavily on semantic;
      # exact phrase matches trust FTS regardless of result count.
      def adaptive_weights(fts_results)
        max_fts = fts_results.map { |r| r[:relevance].to_f }.max || 0
        strong_fts = fts_results.count { |r| r[:relevance].to_f > 0.01 }

        # Alias matches and phrase-bonus results (relevance > 1.0) are
        # high-confidence FTS signals. Trust FTS heavily to prevent
        # semantic search from burying exact quotes.
        if max_fts > 1.0
          [0.85, 0.15]
        # Strong FTS results (relevance > 0.1 means phrase bonus likely
        # fired): trust FTS even for question queries.
        elsif max_fts > 0.1
          [FTS_WEIGHT, SEM_WEIGHT]
        elsif question_query?
          # True question queries with weak FTS: lean on semantic
          [0.05, 0.95]
        elsif strong_fts == 0
          [0.1, 0.9]
        elsif strong_fts < 5
          [0.4, 0.6]
        else
          [FTS_WEIGHT, SEM_WEIGHT]
        end
      end

      def question_query?
        @query.strip.match?(/\A(what|where|when|who|why|how|is|does|did|can|should|are)\b/i) ||
          @query.strip.end_with?("?")
      end

      # Detect which languages the query is written in. Returns an array
      # of language codes that should get a scoring boost.
      def detect_query_languages
        if @query.match?(/[\u0590-\u05FF]/)
          %w[he hbo arc]
        elsif @query.match?(/[\u0370-\u03FF\u1F00-\u1FFF]/)
          %w[grc el-koine]
        else
          %w[en]
        end
      end

      NT_BOOKS = %w[
        matthew mark luke john acts romans 1-corinthians 2-corinthians
        galatians ephesians philippians colossians 1-thessalonians
        2-thessalonians 1-timothy 2-timothy titus philemon hebrews
        james 1-peter 2-peter 1-john 2-john 3-john jude revelation
      ].to_set.freeze

      OT_BOOKS = %w[
        genesis exodus leviticus numbers deuteronomy joshua judges ruth
        1-samuel 2-samuel 1-kings 2-kings 1-chronicles 2-chronicles
        ezra nehemiah esther job psalms proverbs ecclesiastes
        song-of-solomon isaiah jeremiah lamentations ezekiel daniel
        hosea joel amos obadiah jonah micah nahum habakkuk zephaniah
        haggai zechariah malachi
      ].to_set.freeze

      # People → testament they primarily appear in.
      # When a query mentions these names, boost results from their testament.
      PERSON_TESTAMENT = {
        # NT figures
        "jesus" => :nt, "christ" => :nt, "yeshua" => :nt,
        "paul" => :nt, "peter" => :nt, "john" => :nt,
        "james" => :nt, "timothy" => :nt, "titus" => :nt,
        "barnabas" => :nt, "silas" => :nt, "luke" => :nt,
        "stephen" => :nt, "philip" => :nt, "apollos" => :nt,
        "nicodemus" => :nt, "lazarus" => :nt, "martha" => :nt,
        "mary magdalene" => :nt, "pilate" => :nt, "herod" => :nt,
        "pharisees" => :nt, "sadducees" => :nt, "apostles" => :nt,
        "disciples" => :nt,
        # OT figures
        "moses" => :ot, "abraham" => :ot, "david" => :ot,
        "solomon" => :ot, "samuel" => :ot, "elijah" => :ot,
        "elisha" => :ot, "isaiah" => :ot, "jeremiah" => :ot,
        "ezekiel" => :ot, "daniel" => :ot, "noah" => :ot,
        "jacob" => :ot, "isaac" => :ot, "joseph" => :ot,
        "joshua" => :ot, "gideon" => :ot, "samson" => :ot,
        "ruth" => :ot, "esther" => :ot, "nehemiah" => :ot,
        "ezra" => :ot, "job" => :ot, "jonah" => :ot,
        "adam" => :ot, "eve" => :ot, "cain" => :ot, "abel" => :ot,
        "sarah" => :ot, "rebekah" => :ot, "rachel" => :ot,
        "saul" => :ot, "bathsheba" => :ot, "goliath" => :ot,
        "pharaoh" => :ot, "balaam" => :ot, "deborah" => :ot,
      }.freeze

      # Speech/action verbs that indicate the person is doing something
      # in the verse, not just being referenced.
      SPEECH_ACTION_VERBS = %w[
        said answered spoke told asked taught commanded replied cried
        declared proclaimed called instructed warned rebuked blessed
        prayed healed raised sent went came took gave brought wrote
        preached warned exhorted admonished charged urged prophesied
      ].freeze

      SPEECH_VERB_PATTERN = Regexp.new(
        "(#{SPEECH_ACTION_VERBS.join('|')})",
        Regexp::IGNORECASE
      ).freeze

      # Check if the person is the actor/speaker in a verse body.
      # Much more flexible than the old regex: handles patterns like
      # "Jesus answered and said", "Then Jesus said to them",
      # "And Jesus, answering, said", "Jesus went up", etc.
      def person_is_actor?(body, person)
        # Pattern 1: Person followed by verb within a few words
        # "Jesus said", "Jesus answered and said", "Then Jesus went"
        return true if body.match?(/\b#{Regexp.escape(person)}\b.{0,40}#{SPEECH_VERB_PATTERN}/i)

        # Pattern 2: Verb preceded by person within a few words
        # "said Jesus", "answered Jesus unto them"
        return true if body.match?(/#{SPEECH_VERB_PATTERN}.{0,20}\b#{Regexp.escape(person)}\b/i)

        # Pattern 3: Person with possessive acting
        # "Jesus' disciples", "Jesus's teaching"
        return true if body.match?(/\b#{Regexp.escape(person)}['s]*\s+(teaching|word|command|parable|saying|prayer|miracle)/i)

        false
      end

      # Detect the primary person mentioned in the query.
      # Returns the lowercase name or nil.
      def detect_person_name
        query_lower = @query.downcase
        # Check multi-word names first (e.g. "mary magdalene" before "mary")
        PERSON_TESTAMENT.keys.sort_by { |k| -k.length }.each do |name|
          return name if query_lower.include?(name)
        end
        nil
      rescue
        nil
      end

      # Detect if the query mentions a known biblical figure and return
      # the set of book_slugs to boost. Returns nil if no figure detected.
      def detect_testament_books
        query_lower = @query.downcase
        testament = nil

        PERSON_TESTAMENT.each do |person, test|
          if query_lower.include?(person)
            testament = test
            break
          end
        end

        return nil unless testament
        testament == :nt ? NT_BOOKS : OT_BOOKS
      end

      # Detect whether this is a person-topic query pattern like
      # "What did Jesus teach about forgiveness?" or
      # "Paul's teaching on justification"
      def person_topic_query?
        detect_person_name && extract_topic_words.any?
      end

      # Extract topic words from the query — everything that isn't a
      # person name, stop word, or question scaffold. These are the
      # conceptual terms the user is searching for.
      def extract_topic_words
        return @topic_words if defined?(@topic_words)
        person = detect_person_name
        words = @query.gsub(/[?!.,;:'"]/, "").split
        @topic_words = words.reject { |w|
          dw = w.downcase
          STOP_WORDS.include?(dw) ||
            (person && person.split.include?(dw)) ||
            PERSON_TESTAMENT.key?(dw)
        }.map(&:downcase).uniq
      end

      # Find canonical_ref IDs that fall within pericopes whose names
      # match the topic words. Returns { ref_ids: Set } or empty hash.
      #
      # Example: query "Jesus teach forgiveness" with topic ["forgiveness"]
      # finds pericope "The Unforgiving Servant" (Matt 18:21-35) and
      # "Forgiveness" (Rom 3:21-28), then returns all canonical_ref IDs
      # within those pericope ranges.
      def find_pericope_ords(topic_words, person_name = nil)
        return {} unless defined?(Pericope) && Pericope.table_exists?
        return {} if topic_words.empty?

        conn = ApplicationRecord.connection

        # Build a query that matches pericope names containing any topic word.
        # Use ILIKE for case-insensitive substring matching.
        conditions = topic_words.map { |w|
          "p.name ILIKE #{conn.quote("%#{ApplicationRecord.sanitize_sql_like(w)}%")}"
        }

        # Also match on the person name if provided (pericopes like
        # "Jesus Heals the Blind Man", "Paul in Athens")
        if person_name
          conditions << "p.name ILIKE #{conn.quote("%#{ApplicationRecord.sanitize_sql_like(person_name)}%")}"
        end

        rows = conn.select_all(<<~SQL)
          SELECT cr.id AS canonical_ref_id
          FROM pericopes p
          JOIN canonical_refs cr
            ON cr.canonical_work_id = p.canonical_work_id
            AND cr.ord <@ p.canonical_range
          WHERE (#{conditions.join(" OR ")})
          LIMIT 500
        SQL

        ref_ids = rows.map { |r| r["canonical_ref_id"].to_i }.to_set
        ref_ids.any? ? { ref_ids: ref_ids } : {}
      rescue => e
        Rails.logger.warn("[SemanticMerge] pericope lookup failed: #{e.message}")
        {}
      end

      # Find work_unit IDs near (within the same pericope or within ~5 verses
      # of) a verse that mentions the named person. This handles the common
      # pattern where Jesus speaks for several verses but is only named in
      # the first verse of the speech.
      def find_person_context_ids(scored, person_name)
        # Collect canonical_ref_ids of verses that mention the person
        person_ref_ids = scored.values
          .select { |s| s[:result][:body].to_s.downcase.include?(person_name) }
          .map { |s| s[:result][:canonical_ref_id] }
          .compact
          .uniq

        return Set.new if person_ref_ids.empty?

        # Find all work_unit IDs within a small range of those references
        # (same canonical_work, ord within 5). This catches verses in the
        # same speech/narrative block.
        conn = ApplicationRecord.connection
        ref_id_list = person_ref_ids.first(20).join(",")

        rows = conn.select_all(<<~SQL)
          SELECT DISTINCT wu2.id
          FROM canonical_refs cr1
          JOIN canonical_refs cr2
            ON cr2.canonical_work_id = cr1.canonical_work_id
            AND cr2.ord BETWEEN cr1.ord - 3 AND cr1.ord + 5
          JOIN work_units wu2 ON wu2.canonical_ref_id = cr2.id
          WHERE cr1.id IN (#{ref_id_list})
        SQL

        rows.map { |r| r["id"].to_i }.to_set
      rescue => e
        Rails.logger.warn("[SemanticMerge] person context lookup failed: #{e.message}")
        Set.new
      end

      def build_scope_sql(conn, skip_language: false)
        parts = []
        if @scope.is_a?(Hash)
          if @scope[:work].present?
            parts << "AND w.slug = #{conn.quote(@scope[:work])}"
          end
          if @scope[:work_types].is_a?(Array)
            types = @scope[:work_types].map { |t| conn.quote(t) }.join(", ")
            parts << "AND w.work_type IN (#{types})"
          end
          unless skip_language
            if @scope[:languages].is_a?(Array)
              langs = @scope[:languages].map { |l| conn.quote(l) }.join(", ")
              parts << "AND w.language IN (#{langs})"
            end
            if @scope[:language].present?
              parts << "AND w.language = #{conn.quote(@scope[:language])}"
            end
          end
        end
        parts.join("\n")
      end
    end
  end
end
