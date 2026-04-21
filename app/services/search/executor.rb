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

    def initialize(raw_query, scope: nil, page: 1, per_page: 25)
      @raw_query = raw_query.to_s.strip
      @scope = apply_default_scope(scope)
      @page = page
      @per_page = per_page
    end

    def call
      classified = QueryClassifier.classify(@raw_query)

      result = dispatch(classified)

      # Passage alias lookup: if the query matches a known passage nickname
      # (e.g. "golden rule", "shepherd psalm", "prodigal son"), inject the
      # target passage at the top of results.
      if classified.type == :text
        result = inject_alias_matches(result)
      end

      # Transliteration fallback: if text search returned very few results and
      # the query is a single Latin-script word (likely a transliteration like
      # "agape", "hesed", "shalom"), try matching lemma transliterations.
      # Only replace when text results are truly sparse (< 5) — words like
      # "Hallelujah" appear in English text and shouldn't be diverted.
      if classified.type == :text && result.total_count < 5 && latin_script?(@raw_query) && !@raw_query.include?(" ")
        transliteration_result = try_transliteration_fallback(classified.query)
        result = transliteration_result if transliteration_result && !transliteration_result.empty?
      end

      # Pericope-based retrieval: ONLY for question queries ("What did
      # Jesus say about war?"). Non-question queries use FTS + aliases.
      if classified.type == :text && question_query?(@raw_query)
        result = Strategies::PericopeRetrieval.new(
          @raw_query, result, scope: @scope
        ).call
      end

      # Semantic enrichment: if embeddings are available and mode is hybrid,
      # merge embedding results into the FTS results.
      if classified.type == :text && semantic_mode? && embeddings_available?
        result = Strategies::SemanticMerge.new(
          @raw_query, result,
          scope: @scope, page: @page, per_page: @per_page
        ).call
      end

      # For English text searches, also run cross-language search for the sidebar card
      if classified.type == :text && result.cross_language_card.nil?
        card = Strategies::CrossLanguageSearch.new(classified.query).call
        if card
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

      result
    end

    private

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
        Strategies::TextSearch.new(classified.query, scope: @scope, page: @page, per_page: @per_page).call
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
        # Filter fuzzy matches: require that the alias name shares at
        # least one content word with the query (after synonym expansion).
        # This prevents "Thou shalt not kill" matching "You Shall Not
        # Steal" — they're trigram-similar but semantically different.
        query_words = content_words_for(@raw_query)
        matches = candidates.select { |m|
          alias_words = m.name.downcase.split(/\s+/).to_set
          (query_words & alias_words).any?
        }.first(3)
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

    # Semantic search is enabled by default when embeddings exist.
    # Users can opt out via scope[:mode] = "keyword".
    def semantic_mode?
      @scope[:mode] != "keyword"
    end

    # Check if any work_units have embeddings loaded.
    # Cached for the lifetime of this Executor instance.
    def embeddings_available?
      return @embeddings_available if defined?(@embeddings_available)
      @embeddings_available = WorkUnit.where.not(body_embedding: nil).exists?
    end
  end
end
