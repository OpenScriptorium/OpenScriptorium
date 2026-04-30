module Search
  class Executor
    # Main entry point for all search. Classifies the query, dispatches to
    # the right strategy, and returns a ResultSet.

    # Scripture work_types — searched by default. Commentary, treatise,
    # and other non-scripture types are excluded unless the user passes
    # scope: { work_types: "all" } or picks a specific work.
    SCRIPTURE_TYPES = %w[
      scripture_translation scripture_original
      pseudepigraphon apocalypse apostolic_father
    ].freeze

    # SEARCH_PLAN.md Phase 2. On by default; set SEARCH_CONCEPTS=off
    # to disable the concept layer (a rollback knob if anything looks
    # wrong in prod without needing a redeploy). When off, the concept
    # path makes zero DB calls.
    CONCEPTS_ENABLED = ENV.fetch("SEARCH_CONCEPTS", "on") != "off"

    # External topical-index integration (OpenBible Topics + Sefaria Topics).
    # Same rollback knob: set SEARCH_TOPICS=off to disable. When off,
    # the topic path makes zero DB calls.
    TOPICS_ENABLED = ENV.fetch("SEARCH_TOPICS", "on") != "off"

    # Per-stage timing instrumentation. Set SEARCH_TIMING=1 to emit a
    # one-line breakdown to stderr after each query showing milliseconds
    # spent in dispatch, alias, transliteration, pericope, semantic,
    # concept, topic, cross-language. Zero-cost when off.
    TIMING_ENABLED = ENV.fetch("SEARCH_TIMING", "0") == "1"

    def initialize(raw_query, scope: nil, page: 1, per_page: 25)
      @raw_query = raw_query.to_s.strip
      @scope = apply_default_scope(scope)
      @page = page
      @per_page = per_page
      @timings = {} if TIMING_ENABLED
    end

    def call
      classified = QueryClassifier.classify(@raw_query)

      result = time_stage(:dispatch) { dispatch(classified) }

      # Person-topic queries have their own ranking pipeline — skip the
      # general text post-processing (aliases, pericope, semantic merge).
      is_text = classified.type == :text && result.query_type != :person_topic

      # Passage alias lookup: if the query matches a known passage nickname
      # (e.g. "golden rule", "shepherd psalm", "prodigal son"), inject the
      # target passage at the top of results.
      if is_text
        result = time_stage(:alias) { inject_alias_matches(result) }
      end

      # Transliteration fallback: if text search returned very few results and
      # the query is a single Latin-script word (likely a transliteration like
      # "agape", "hesed", "shalom"), try matching lemma transliterations.
      # Only replace when text results are truly sparse (< 5) — words like
      # "Hallelujah" appear in English text and shouldn't be diverted.
      if is_text && result.total_count < 5 && latin_script?(@raw_query) && !@raw_query.include?(" ")
        transliteration_result = time_stage(:translit) { try_transliteration_fallback(classified.query) }
        result = transliteration_result if transliteration_result && !transliteration_result.empty?
      end

      # Pericope-based retrieval: ONLY for question queries ("What did
      # Jesus say about war?"). Non-question queries use FTS + aliases.
      #
      # Skip pericope retrieval when the topic gate would fire — topics
      # handle thematic queries more precisely. PericopeRetrieval's
      # MULTI_HOP expansion grabs broadly-related pericopes (e.g.,
      # "anxiety" → "peace trust faith" → Faith pericopes injected at
      # relevance ~8.0), which then dominates topic-injected verses
      # (relevance ~4.5) and buries the actual right answer. For narrative
      # questions ("what happened at the tower of Babel") the topic gate
      # doesn't fire and pericope retrieval still runs.
      pericope_eligible = is_text && question_query?(@raw_query) &&
                          (!TOPICS_ENABLED || !topic_retrieval_helpful?(result))
      if pericope_eligible
        result = time_stage(:pericope) {
          Strategies::PericopeRetrieval.new(@raw_query, result, scope: @scope).call
        }
      end

      # Semantic enrichment: if embeddings are available and mode is hybrid,
      # merge embedding results into the FTS results.
      # Runs for text AND person-topic queries — paraphrase-friendly verses
      # like Matt 10:34 ("I came not to send peace, but a sword") are key
      # answers to "what did Jesus say about war?" but contain none of the
      # topic words, so PersonTopicSearch's pure-FTS path misses them.
      # SemanticMerge has dedicated person-topic handling (focused encoding,
      # person-context expansion) that fires when query_type == :person_topic.
      semantic_eligible = (is_text || result.query_type == :person_topic) &&
                          semantic_mode? && embeddings_available?
      if semantic_eligible
        sem_strategy = Strategies::SemanticMerge.new(
          @raw_query, result,
          scope: @scope, page: @page, per_page: @per_page
        )
        result = time_stage(:semantic) { sem_strategy.call }
        # Cache the query embedding for downstream gates (TopicRetrieval
        # intent gate, Phase B). Avoids a redundant ONNX inference.
        @cached_query_embedding = sem_strategy.query_embedding
      end

      # Concept retrieval: merge curated concept → signature-verse
      # matches into the result set. Runs for text AND person-topic
      # query types so "what did Jesus say about forgiveness" also
      # benefits from a "Forgiveness" concept pointing at Matt 6:14.
      # Gated by CONCEPTS_ENABLED so it's a zero-cost no-op when off.
      if CONCEPTS_ENABLED && (is_text || result.query_type == :person_topic)
        concept_result = time_stage(:concept) {
          Strategies::ConceptRetrieval.new(@raw_query, scope: @scope, per_page: @per_page).call
        }
        result = Strategies::ConceptRetrieval.merge(result, concept_result, per_page: @per_page)
      end

      # Topic retrieval: merge external topical-index matches (OpenBible +
      # Sefaria) into the result set. Same base gating as concepts, plus
      # an intent gate — topics only fire when the query *shape* looks
      # thematic (asking about a topic) rather than specific (quoting a
      # verse, naming a passage). The gate eliminates the regression on
      # paraphrase / named-passage queries from the 2026-04-28 audit
      # while preserving the natural_language wins.
      if TOPICS_ENABLED && (is_text || result.query_type == :person_topic) &&
         topic_retrieval_helpful?(result)
        topic_result = time_stage(:topic) {
          Strategies::TopicRetrieval.new(
            @raw_query, scope: @scope, per_page: @per_page,
            query_embedding: @cached_query_embedding
          ).call
        }
        result = Strategies::TopicRetrieval.merge(result, topic_result, per_page: @per_page)
      end

      # For English text searches, also run cross-language search for the sidebar card
      if (is_text || result.query_type == :person_topic) && result.cross_language_card.nil?
        card = time_stage(:xlang) { Strategies::CrossLanguageSearch.new(classified.query).call }
        if card
          emit_timings!
          return ResultSet.new(
            results: result.results,
            query: result.query,
            query_type: result.query_type,
            total_count: result.total_count,
            facets: result.facets,
            cross_language_card: card,
            redirect: result.redirect,
            page: result.page,
            per_page: result.per_page
          )
        end
      end

      emit_timings!
      result
    end

    private

    # No-op when SEARCH_TIMING isn't set.
    def time_stage(name)
      return yield unless TIMING_ENABLED
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      @timings[name] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
      result
    end

    def emit_timings!
      return unless TIMING_ENABLED
      total = @timings.values.sum.round
      parts = @timings.map { |k, v| "#{k}=#{v.round}" }.join(" ")
      preview = @raw_query.length > 50 ? "#{@raw_query[0, 50]}..." : @raw_query
      $stderr.puts "[SEARCH_TIMING] #{total}ms total | #{parts} | q=#{preview.inspect}"
    end

    def dispatch(classified)
      case classified.type
      when :citation
        Strategies::CitationSearch.new(classified.query).call
      when :strongs
        Strategies::StrongsSearch.new(classified.query, scope: @scope, page: @page, per_page: @per_page).call
      when :lemma
        Strategies::LemmaSearch.new(classified.query, scope: @scope, page: @page, per_page: @per_page).call
      when :hebrew
        Strategies::ScriptSearch.new(classified.query, script: :hebrew, scope: @scope, page: @page, per_page: @per_page).call
      when :greek
        Strategies::ScriptSearch.new(classified.query, script: :greek, scope: @scope, page: @page, per_page: @per_page).call
      when :morphological
        Strategies::MorphologicalSearch.new(classified.query, scope: @scope, page: @page, per_page: @per_page).call
      when :proximity
        extra = classified.extra
        Strategies::ProximitySearch.new(
          extra[:term_a], extra[:term_b],
          distance: extra[:distance], scope: @scope, page: @page, per_page: @per_page
        ).call
      when :regex
        Strategies::RegexSearch.new(classified.query, scope: @scope, page: @page, per_page: @per_page).call
      when :xref_traversal
        Strategies::XrefTraversalSearch.new(classified.query, scope: @scope, page: @page, per_page: @per_page).call
      when :apparatus
        Strategies::ApparatusSearch.new(
          scope: @scope, variant_type: classified.extra[:variant_type],
          page: @page, per_page: @per_page
        ).call
      when :syntax
        Strategies::SyntaxSearch.new(
          classified.query,
          extra: classified.extra,
          scope: @scope, page: @page, per_page: @per_page
        ).call
      else
        # Person-topic queries ("What did Jesus say about money?") use a
        # dedicated strategy that combines topic FTS with person-proximity
        # boosting. Only fires when the query has a recognized person name
        # AND at least one topic word.
        person, topic_words = detect_person_topic(classified.query)
        if person
          Strategies::PersonTopicSearch.new(
            person, topic_words,
            raw_query: classified.query,
            scope: @scope, page: @page, per_page: @per_page
          ).call
        else
          Strategies::TextSearch.new(classified.query, scope: @scope, page: @page, per_page: @per_page).call
        end
      end
    end

    # Check if a string is Latin script (transliteration candidate)
    def latin_script?(str)
      str.match?(/\A[a-zA-Zāēīōūâêîôûḥśšṭṣḍḡṯḇḵp̄'ʾʿ\s]+\z/)
    end

    # Try to find a lemma by transliteration and return its occurrences.
    # Prefers common words (lowercase gloss) over proper names (capitalized gloss)
    # and higher frequency over lower, so "shalom" finds peace not Shallum.
    def try_transliteration_fallback(query)
      conn = Lemma.connection
      quoted = conn.quote(query)

      # Ordering: prefer common words (lowercase gloss) over proper names,
      # then highest frequency. This prevents "shalom" → Shallum.
      prefer_common = "CASE WHEN primary_gloss ~ '^[a-z]' THEN 0 ELSE 1 END, frequency DESC"

      # Try exact match first, then synonym-expanded form
      lemma = Lemma.where("transliteration ILIKE ?", query)
                   .where("frequency > 0")
                   .order(Arel.sql(prefer_common)).first
      unless lemma
        expanded = conn.select_value("SELECT expand_bible_synonyms(#{quoted})")
        if expanded && expanded != query.downcase
          lemma = Lemma.where("transliteration ILIKE ?", expanded)
                       .where("frequency > 0")
                       .order(Arel.sql(prefer_common)).first
        end
      end

      # Strip dots and diacritics (STEP uses "che.sed" for hesed, "agapē" for agape)
      search_terms = [query]
      expanded ||= conn.select_value("SELECT expand_bible_synonyms(#{quoted})")
      search_terms << expanded if expanded && expanded != query.downcase

      search_terms.each do |term|
        lemma ||= Lemma
          .where("REPLACE(TRANSLATE(transliteration, 'āēīōūâêîôûḥśšṭṣḍḡṯḇḵ', 'aeiouaeiouhsststdgtbk'), '.', '') ILIKE ?", term)
          .where("frequency > 0")
          .order(Arel.sql(prefer_common))
          .first
      end

      # Trigram similarity with higher threshold to avoid false positives
      lemma ||= Lemma
        .where("similarity(REPLACE(transliteration, '.', ''), #{quoted}) > 0.35")
        .where("frequency > 0")
        .order(Arel.sql("CASE WHEN primary_gloss ~ '^[a-z]' THEN 0 ELSE 1 END, similarity(REPLACE(transliteration, '.', ''), #{quoted}) DESC"))
        .first

      return nil unless lemma

      Strategies::LemmaSearch.new(lemma.normalized, scope: @scope, page: @page, per_page: @per_page).call
    end

    # Default scope: limit to English scripture work types unless the
    # user has explicit filters active.
    def apply_default_scope(scope)
      scope = (scope || {}).dup

      # If user picked a specific work, don't add any filtering
      return scope if scope[:work].present?

      # If user has explicit section or tradition filters, don't add
      # default work_types (the section filter handles corpus narrowing)
      has_explicit_filters = scope[:sections].is_a?(Array) && scope[:sections].any? ||
                             scope[:traditions].is_a?(Array) && scope[:traditions].any? ||
                             scope[:book].present?

      # If user explicitly asked for all types, strip our defaults
      if scope[:work_types] == "all"
        scope.delete(:work_types)
      elsif !has_explicit_filters
        scope[:work_types] = SCRIPTURE_TYPES unless scope.key?(:work_types)
      end

      # Default to English + original-language works to avoid French/German
      # contamination. Users can override via the language filter.
      unless scope.key?(:language)
        scope[:languages] = %w[en he hbo arc el-koine grc la]
      end

      scope
    end

    # Look up passage aliases matching the query. If found, fetch the
    # target passage(s) and prepend them to the results so they appear first.
    def inject_alias_matches(result)
      return result unless PassageAliasName.table_exists?

      # Exact match first. For short queries (≤4 words, likely nicknames),
      # also try trigram fuzzy matching. Skip fuzzy for longer queries to
      # avoid "blessed are the poor in spirit" matching "Blessed Is the Man".
      matches = PassageAliasName.matching(@raw_query)
                  .includes(passage_alias: [])
                  .limit(5)

      if matches.empty? && @raw_query.split.size <= 4
        candidates = PassageAliasName.fuzzy(@raw_query)
                       .includes(passage_alias: [])
                       .limit(10)
        # Filter and rank fuzzy matches by content-word overlap with the
        # query (after synonym expansion). Sort by overlap count so
        # "Honor Your Father and Mother" (2 overlaps: honor, father)
        # ranks above "Our Father" (1 overlap: father).
        query_words = content_words_for(@raw_query)
        matches = candidates
          .map { |m|
            alias_words = m.name.downcase.split(/\s+/).to_set
            overlap = (query_words & alias_words).size
            [m, overlap]
          }
          .select { |_, overlap| overlap > 0 }
          .sort_by { |_, overlap| -overlap }
          .map(&:first)
          .first(3)
      end

      return result if matches.empty?

      refs = matches.map { |m| m.passage_alias.ref }.uniq
      alias_results = fetch_passages_for_refs(refs)
      return result if alias_results.empty?

      # Deduplicate: remove any FTS results that the alias already covers
      alias_citations = alias_results.map { |r| r[:citation] }.compact.to_set
      filtered = result.results.reject { |r| alias_citations.include?(r[:citation]) }

      ResultSet.new(
        results: alias_results + filtered,
        query: result.query,
        query_type: result.query_type,
        total_count: result.total_count + alias_results.size,
        facets: result.facets,
        cross_language_card: result.cross_language_card,
        redirect: result.redirect,
        page: result.page,
        per_page: result.per_page
      )
    end

    # Given ref strings like "Matt 7:12" or "Luke 15:11-32", find matching
    # work_units and format them as search results.
    #
    # When alias_names_by_ref is provided, ranged refs use FTS relevance to
    # pick the CORE verse instead of the introductory first verse. For
    # example, "Aaronic Blessing" (Num 6:22-27) skips v22 ("The LORD spoke
    # to Moses") and returns v24 ("The LORD bless you and keep you").
    #
    # The scoring uses all known alias names for the passage (not just the
    # user's query), so phrases like "The Lord Bless You and Keep You"
    # directly match the verse text even when the user typed "Aaronic
    # Blessing".
    DEFAULT_LOOKAHEAD = 15 # Default max verses into a range to consider
    MAX_LOOKAHEAD_CAP = 50 # Hard cap for very large ranges

    def fetch_passages_for_refs(refs)
      results = []
      refs.each do |ref|
        # Expand multi-ref: "Matt 13:1-9; Mark 4:1-9; Luke 8:4-8"
        # Process EACH semicolon-separated ref to show all parallel passages
        sub_refs = ref.split(";").map(&:strip)
        sub_refs.each do |sub_ref|
        # Handle comma-separated sub-ranges: "Matt 13:1-9, 18-23" → "Matt 13:1-9"
        primary = sub_ref.split(",").first.strip
        # Detect whether this is a range (has a dash with digits after it)
        is_range = primary.match?(/-[\d:]+$/)
        # Extract end verse number for dynamic lookahead calculation
        range_end_verse = nil
        if is_range
          end_match = primary.match(/-(\d+)$/)
          range_end_verse = end_match[1].to_i if end_match
        end
        # Strip the end of range to get the start ref
        primary = primary.sub(/-[\d:]+$/, "")
        # Normalize numbered-book abbreviations: "1Sam" → "1 Sam", "2Kgs" → "2 Kgs"
        # The JSON aliases use SBL compact form (no space) but the database
        # stores "1 Sam", "2 Kgs", etc. (space after the digit prefix).
        primary = primary.sub(/\A(\d)([A-Z])/, '\1 \2')
        # Handle chapter-only ("Ps 23") — append :1
        unless primary.match?(/:\d+/)
          primary = "#{primary}:1"
        end

        # Find a canonical_ref that has work_units (multiple canonical_works
        # may share the same citation — prefer ones with actual content)
        cr = CanonicalRef
               .joins("INNER JOIN work_units ON work_units.canonical_ref_id = canonical_refs.id")
               .where("canonical_refs.sbl_citation = ?", primary)
               .first
        cr ||= CanonicalRef
                 .joins("INNER JOIN work_units ON work_units.canonical_ref_id = canonical_refs.id")
                 .where("canonical_refs.sbl_citation LIKE ?", "#{primary.sub(/:\d+$/, '')}:%")
                 .order(:ord)
                 .first
        next unless cr

        # For ranged aliases (Gen 5:21-24), try to find the verse within
        # the range that actually contains the user's query text. This
        # handles "Enoch walked with God" → Gen 5:24 (not 5:21).
        # Fall back to the first verse if no text match is found.
        if is_range
          wu = find_best_verse_in_range(cr, range_end_verse, @raw_query)
        end
        wu ||= WorkUnit.joins(:work)
                 .where(canonical_ref_id: cr.id)
                 .where(works: { language: "en" })
                 .includes(:canonical_ref, work: :license)
                 .first
        wu ||= WorkUnit.joins(:work)
                 .where(canonical_ref_id: cr.id)
                 .includes(:canonical_ref, work: :license)
                 .first
        next unless wu

        results << {
          id: wu.id,
          work_slug: wu.work.slug,
          work_title: wu.work.title,
          language: wu.work.language,
          canonical_ref_id: wu.canonical_ref_id,
          citation: wu.canonical_ref.sbl_citation,
          hierarchy: wu.canonical_ref.hierarchy,
          body: wu.body,
          headline: wu.body,
          relevance: 10.0, # Above normal FTS but not untouchable
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key,
          alias_match: true
        }
      end # sub_refs.each
      end # refs.each
      results
    end

    # For ranged alias matches, scan the range for a verse whose text
    # contains the user's query (case-insensitive). Returns the WorkUnit
    # or nil if no verse matches.
    def find_best_verse_in_range(start_cr, range_end_verse, query)
      return nil if query.blank?

      lookahead = compute_lookahead(start_cr, range_end_verse)
      candidate_crs = CanonicalRef
                        .where(canonical_work_id: start_cr.canonical_work_id)
                        .where("ord >= ? AND ord < ?", start_cr.ord, start_cr.ord + lookahead)
                        .order(:ord)
                        .pluck(:id)
      return nil if candidate_crs.empty?

      query_lower = query.downcase
      # Also try with synonym expansion
      conn = ApplicationRecord.connection
      expanded = conn.select_value("SELECT expand_bible_synonyms(#{conn.quote(query)})")

      wus = WorkUnit.joins(:work)
              .where(canonical_ref_id: candidate_crs)
              .where(works: { language: "en" })
              .includes(:canonical_ref, work: :license)

      wus.each do |wu|
        body_lower = wu.body.to_s.downcase
        if body_lower.include?(query_lower) ||
           (expanded && body_lower.include?(expanded.downcase))
          return wu
        end
      end
      nil
    end

    # Given the first canonical_ref in a range and a list of alias names,
    # search the range for the verse whose text best matches the user's
    # query phrase. Uses a two-tier scoring system:
    #
    # 1. **Phrase match (ILIKE)** — verses containing the query or any alias
    #    name as a contiguous substring get a large bonus (10x). This is the
    #    strongest signal: "can these bones live" should find the verse that
    #    actually says those words, not one that merely repeats "bones".
    #
    # 2. **FTS token rank** — ties among phrase-matching verses (or when no
    #    phrase matches) are broken by ts_rank_cd on individual words.
    #
    # Returns nil if no verse qualifies, letting the caller fall back to the
    # default first-verse lookup.
    def pick_best_verse_in_range(start_cr, alias_names, lookahead: DEFAULT_LOOKAHEAD)
      # Simple approach: check if the user's query or any long alias name
      # appears as a PHRASE in a later verse. If so, return that verse.
      # Otherwise return nil (caller uses first verse).
      #
      # This handles: "Aaronic Blessing" → Num 6:24 (has "The LORD bless you")
      # Without breaking: "Talents" → Matt 25:14 (first verse, no phrase match)

      candidate_crs = CanonicalRef
                        .where(canonical_work_id: start_cr.canonical_work_id)
                        .where("ord >= ? AND ord < ?", start_cr.ord, start_cr.ord + lookahead)
                        .order(:ord)
                        .pluck(:id)
      return nil if candidate_crs.empty?

      # Collect phrases to search for (query + long alias names)
      phrases = []
      phrases << @raw_query.downcase if @raw_query.split.size >= 3
      alias_names.each do |name|
        phrases << name.downcase if name.split.size >= 4
      end
      return nil if phrases.empty?

      # Find verses containing any phrase
      wus = WorkUnit.joins(:work)
              .where(canonical_ref_id: candidate_crs)
              .where(works: { language: "en" })
              .includes(:canonical_ref, work: :license)

      best = nil
      wus.each do |wu|
        body = wu.body.to_s.downcase
        stripped = body.gsub(/[^a-z\s]/, "")
        if phrases.any? { |p| body.include?(p) || stripped.include?(p) }
          best = wu
          break
        end
      end

      best
    end

    # Compute how many verses ahead to scan for best-verse matching.
    # When we know the range endpoint (e.g. "Matt 5:3-12" → end=12),
    # scan exactly that many verses. For ranges without a clear endpoint
    # (chapter-only refs), fall back to DEFAULT_LOOKAHEAD. Cap at
    # MAX_LOOKAHEAD_CAP for safety on very large ranges.
    def compute_lookahead(start_cr, range_end_verse)
      if range_end_verse
        start_verse = start_cr.hierarchy&.last || 1
        # +2 accounts for possible ord gaps (sub-verses, etc.)
        range_size = (range_end_verse - start_verse + 2).clamp(1, MAX_LOOKAHEAD_CAP)
        range_size
      else
        DEFAULT_LOOKAHEAD
      end
    end

    # Extract content words from a query for alias filtering.
    # Returns a Set of lowercase words, including synonym-expanded forms,
    # with stop words removed. Used to verify that fuzzy alias matches
    # share semantic overlap with the query.
    ALIAS_STOP_WORDS = %w[
      a an the in on at to of for by is it be was were are am
      has have had do does did will shall would should can could
      may might must not no and or but if with from thou thy
      thee ye shalt hast doth unto you your he she his her him
      they them their we our us i me my who whom what that this
      which how when where why all
    ].to_set.freeze

    def content_words_for(query)
      words = query.downcase.gsub(/[^a-z\s]/, "").split
      content = words.reject { |w| ALIAS_STOP_WORDS.include?(w) || w.length < 2 }.to_set
      # Also add synonym-expanded forms
      conn = ApplicationRecord.connection
      expanded = conn.select_value("SELECT expand_bible_synonyms(#{conn.quote(query)})")
      if expanded
        expanded.downcase.split.each do |w|
          content << w unless ALIAS_STOP_WORDS.include?(w) || w.length < 2
        end
      end
      content
    end

    def question_query?(q)
      q.strip.match?(/\A(what|where|when|who|why|how|is|does|did|can|should|are)\b/i) ||
        q.strip.end_with?("?")
    end

    # Intent gate for TopicRetrieval. Topics fire only when the query
    # *shape* looks thematic — asking about a topic — rather than specific
    # (quoting a verse, paraphrasing one, naming a passage). On the
    # 2026-04-28 audit, ungated topics regressed paraphrase_semantic
    # by 17.5pp because topic-injected verses (relevance ~4.5) overran
    # FTS+semantic correct answers (post-RRF relevance ~0.04).
    #
    # The gate is a fast-path: regex patterns for explicit thematic
    # phrasings, plus a short-query fallback for single-word topical
    # lookups ("anxiety", "war"). A second-layer embedding-similarity
    # gate is planned for the queries this misses.
    THEMATIC_PATTERNS = [
      /\b(verses?|passages?)\s+(about|on|regarding|concerning|of)\b/i,
      /\bwhat\s+(does|do)\s+(the\s+)?(bible|scripture|scriptures)\s+(say|teach)/i,
      /\bwhat\s+(is|are)\s+\w+/i,
      /\bbiblical\s+view\s+of\b/i,
      /\b(in|throughout)\s+(the\s+)?(bible|scripture|scriptures)\b/i,
      /\babout\s+\w+\s+in\s+the\s+bible\b/i
    ].freeze

    # Stop words for the content-word count fallback. Same minimal set
    # used by other gates here — short-circuits "the war" / "of love"
    # being treated as 2-word queries.
    INTENT_GATE_STOP_WORDS = %w[
      a an the of in on at to for and or but is are was were
      that this these those it its with from by my our your
    ].to_set.freeze

    def topic_retrieval_helpful?(result)
      # Person-topic queries are explicitly thematic by detection.
      return true if result.query_type == :person_topic

      q = @raw_query
      return false if q.blank?

      # Phase A — explicit thematic phrasing.
      return true if THEMATIC_PATTERNS.any? { |re| q.match?(re) }

      # Phase A — short keyword queries are usually topical lookup.
      content = q.downcase.gsub(/[^a-z0-9\s]/, " ").split
                 .reject { |w| INTENT_GATE_STOP_WORDS.include?(w) || w.length < 2 }
      return true if content.size <= 2

      # Phase B — embedding similarity to thematic vs non-thematic
      # prototype queries. Catches phrasings the regex patterns miss
      # ("tell me about peace", "show me wisdom verses"). Reuses the
      # query embedding SemanticMerge already computed; if the cache
      # is empty (rare — e.g. SemanticMerge bailed out before encoding),
      # falls back to false rather than triggering a fresh encode.
      thematic_via_embedding?
    end

    # Thematic vs non-thematic prototype queries. The vectors are encoded
    # lazily on first use and memoized at the class level. Queries get
    # classified by whichever side they're more similar to, with a small
    # bias toward firing (thematic_max > non_thematic_max + threshold).
    THEMATIC_PROTOTYPES = [
      "verses about anxiety",
      "what does the bible say about lust",
      "what is grace",
      "biblical view of marriage",
      "passages on forgiveness",
      "tell me about peace in the bible",
      "show me verses on hope",
      "wisdom verses",
      "anxiety in the bible",
      "what is the kingdom of god",
      "scriptures about love",
      "verses on fear",
      "what does scripture teach about money",
      "biblical perspective on suffering"
    ].freeze

    NON_THEMATIC_PROTOTYPES = [
      "for God so loved the world",
      "the lord is my shepherd",
      "blessed are the meek",
      "wash me clean from my sin",
      "Jacob wrestled with the angel",
      "parable of the prodigal son",
      "Magnificat",
      "in the beginning God created",
      "thou shalt not kill",
      "Genesis 1:1",
      "Sermon on the Mount",
      "the writing on the wall",
      "Jesus wept",
      "armor of God"
    ].freeze

    THEMATIC_THRESHOLD = 0.04  # cosine margin: thematic_max must beat non-thematic by this much

    @@prototype_embedding_mutex = Mutex.new

    def self.prototype_embeddings
      return @@prototype_embeddings if defined?(@@prototype_embeddings) && @@prototype_embeddings
      @@prototype_embedding_mutex.synchronize do
        return @@prototype_embeddings if defined?(@@prototype_embeddings) && @@prototype_embeddings
        encoder = Search::EmbeddingEncoder.instance
        return nil unless encoder.model_available?
        thematic = THEMATIC_PROTOTYPES.filter_map { |p| encoder.encode(p) }
        non_thematic = NON_THEMATIC_PROTOTYPES.filter_map { |p| encoder.encode(p) }
        @@prototype_embeddings = { thematic: thematic, non_thematic: non_thematic }
      end
    rescue => e
      Rails.logger.warn("[Executor] prototype embedding failed: #{e.message}")
      nil
    end

    def thematic_via_embedding?
      embedding = @cached_query_embedding
      return false unless embedding
      protos = self.class.prototype_embeddings
      return false unless protos

      thematic_max = protos[:thematic].map { |v| dot(embedding, v) }.max || 0.0
      non_thematic_max = protos[:non_thematic].map { |v| dot(embedding, v) }.max || 0.0
      thematic_max > non_thematic_max + THEMATIC_THRESHOLD
    end

    # Cosine on L2-normalized vectors reduces to dot product.
    # Both sides are normalized in the Qwen3-Embedding fused export.
    def dot(a, b)
      sum = 0.0
      i = 0
      n = a.length
      while i < n
        sum += a[i] * b[i]
        i += 1
      end
      sum
    end

    # Detect person-topic queries like "What did Jesus say about money?"
    # or "Paul's teaching on justification". Returns [person_name, topic_words]
    # or nil if not a person-topic query.
    #
    # Only triggers when:
    # 1. Query contains a recognized biblical person name
    # 2. Query has topic words (not just the person name)
    # 3. Query looks like a question or "about X" pattern (not an exact quote)
    PERSON_NAMES = %w[
      god jesus christ yeshua paul peter john james timothy titus
      barnabas silas luke stephen philip apollos nicodemus lazarus
      martha pilate herod moses abraham david solomon samuel elijah
      elisha isaiah jeremiah ezekiel daniel noah jacob isaac joseph
      joshua gideon samson ruth esther nehemiah ezra job jonah
      adam eve cain abel sarah rebekah rachel leah saul bathsheba
      goliath pharaoh balaam deborah mary naomi
    ].to_set.freeze

    PERSON_TOPIC_STOP = %w[
      what where when who why how does did do is are was were
      the a an of in to for and or but with about from by at on
      that this these those it its they them their he she his her
      can could should would will shall may might
      bible say says said tell tells told teach teaches taught
      verse verses passage passages scripture scriptures
      talk talks about regarding concerning wrote write
    ].to_set.freeze

    def detect_person_topic(query)
      words = query.downcase.gsub(/[?!.,;:'"]/, "").split
      person = words.find { |w| PERSON_NAMES.include?(w) }
      return nil unless person

      # "verse/passage/scripture about X" is a paraphrase/topical query,
      # not a person-topic query, even when X incidentally contains a
      # person's name ("verse about being buried with Christ"). Leave
      # these to TextSearch + semantic merge.
      return nil if query.strip.match?(/\A(a\s+)?(verse|verses|passage|passages|scripture|scriptures|bible)\b/i)

      # Keep second person names as topic words — "David and Goliath"
      # should use "goliath" as the topic, not discard it. Only the
      # FIRST detected person is the subject.
      topic_words = words.reject { |w|
        PERSON_TOPIC_STOP.include?(w) || w == person
      }
      return nil if topic_words.empty?

      # Only trigger for clear question/topic patterns, not exact quotes
      # or narrative queries. "David and Goliath" should stay with TextSearch.
      is_question = query.strip.match?(/\A(what|where|when|who|why|how|does|did|can|should)\b/i) ||
                    query.strip.end_with?("?") ||
                    query.downcase.include?(" about ") ||
                    query.downcase.include?(" regarding ") ||
                    query.downcase.match?(/\bteach\w*\b|\bsay\b|\bsaid\b|\bwrote\b|\bwrite\b/)
      return nil unless is_question

      [person, topic_words]
    end

    # Semantic search is enabled by default when embeddings exist.
    # Users can opt out via scope[:mode] = "keyword".
    def semantic_mode?
      @scope[:mode] != "keyword"
    end

    # Check if Qwen3 corpus embeddings are loaded. The vectors live in the
    # `work_unit_embeddings_qwen3_06b` side table (vector(1024)).
    # Cached for the lifetime of this Executor instance.
    def embeddings_available?
      return @embeddings_available if defined?(@embeddings_available)
      @embeddings_available = ActiveRecord::Base.connection
        .select_value("SELECT 1 FROM work_unit_embeddings_qwen3_06b LIMIT 1")
        .present?
    rescue ActiveRecord::StatementInvalid
      @embeddings_available = false
    end
  end
end
