module Search
  module Strategies
    class CrossLanguageSearch
      # When searching English text, find source-language equivalents via
      # lemma glosses. Returns the top matches from both Hebrew and Greek,
      # showing verbs, nouns, and other forms so the user sees the full
      # lexical picture.

      HEBREW_LANGS = %w[he hbo arc].freeze
      GREEK_LANGS  = %w[el-koine grc].freeze
      MAX_PER_LANGUAGE = 3

      def initialize(query)
        @query = query
      end

      STOPWORDS = Set.new(%w[
        a an the in on at to of for by is it its be was were
        are am been has have had do does did will shall would
        should can could may might must not no nor and or but
        if then than that this these those with from your my
        his her their our its who whom whose which what when
        where how why all any both each every some such thou
        thee thy shalt hast doth unto ye
      ]).freeze

      # Concept synonyms: English words that map to the same biblical concept
      # but are glossed differently in STEP/BDB/LSJ. This bridges the gap
      # between how a user searches ("mercy") and how the lexicon glosses
      # the term ("lovingkindness", "steadfast love").
      CONCEPT_SYNONYMS = {
        "law" => %w[instruction teaching statute commandment],
        "mercy" => %w[lovingkindness steadfast compassion kindness],
        "worship" => %w[bow prostrate homage],
        "judge" => %w[judge govern rule],
        "servant" => %w[slave bondservant],
        "forgive" => %w[pardon forgive],
        "forgiveness" => %w[pardon forgiveness],
        "sin" => %w[sin transgression iniquity],
        "praise" => %w[praise thank bless],
        "save" => %w[save deliver rescue],
        "salvation" => %w[salvation deliverance rescue],
        "redeem" => %w[redeem ransom],
        "redemption" => %w[redemption ransom],
        "wrath" => %w[wrath anger fury],
        "blessing" => %w[blessing bless],
        "fear" => %w[fear awe dread reverence],
        "joy" => %w[joy gladness rejoice],
        "hope" => %w[hope wait expect],
        "repentance" => %w[repentance relent comfort],
        "obey" => %w[obey hear listen],
        "love" => %w[love beloved],
      }.freeze

      def call
        return nil if @query.blank?

        # For multi-word queries, decompose into content words and search
        # each individually, then merge results by picking the best per
        # language across all sub-queries.
        words = @query.downcase.gsub(/[?!.,;:'"()]/, "").split(/\s+/).reject { |w| STOPWORDS.include?(w) || w.length < 2 }

        if words.size > 1
          return search_multiple_words(words)
        end

        conn = ApplicationRecord.connection

        # Build gloss patterns: the query itself + any concept synonyms.
        # Use hyphen-aware word boundaries so "law" doesn't match "mother-in-law".
        search_terms = [@query.downcase]
        if CONCEPT_SYNONYMS.key?(@query.downcase)
          search_terms.concat(CONCEPT_SYNONYMS[@query.downcase])
          search_terms.uniq!
        end

        gloss_patterns = search_terms.map { |term|
          escaped = Regexp.escape(term)
          conn.quote("(^|[^a-zA-Z-])#{escaped}([^a-zA-Z-]|$)")
        }
        combined_pattern = gloss_patterns.map { |p| "primary_gloss ~* #{p}" }.join(" OR ")

        hebrew = find_candidates(combined_pattern, conn, HEBREW_LANGS)
        greek  = find_candidates(combined_pattern, conn, GREEK_LANGS)

        top_hebrew = pick_top(hebrew, @query, MAX_PER_LANGUAGE)
        top_greek  = pick_top(greek, @query, MAX_PER_LANGUAGE)

        return nil if top_hebrew.empty? && top_greek.empty?

        format_entries = ->(list) {
          list.map { |l|
            {
              id: l.id,
              lemma: l.lemma,
              normalized: l.normalized,
              transliteration: l.transliteration,
              language: l.language,
              primary_gloss: l.primary_gloss,
              part_of_speech: l.part_of_speech,
              frequency: l.frequency
            }
          }
        }

        {
          hebrew: format_entries.(top_hebrew),
          greek: format_entries.(top_greek)
        }
      end

      private

      # Person names and common verbs to deprioritize in sidebar
      PERSON_NAMES = %w[jesus christ paul peter moses david abraham solomon
        samuel elijah elisha isaiah jeremiah ezekiel daniel john james
        mary martha sarah ruth esther].freeze
      COMMON_VERBS = %w[say said tell told speak spoke teach taught
        ask asked go went come came give gave make made
        about concerning regarding].freeze

      def search_multiple_words(words)
        conn = ApplicationRecord.connection

        all_hebrew = []
        all_greek = []

        # Only search topic words for the sidebar — skip person names and
        # common verbs that produce junk matches ("say" → סֵפֶל)
        topic_words = words.reject { |w| PERSON_NAMES.include?(w) || COMMON_VERBS.include?(w) }
        topic_words = words.first(2) if topic_words.empty? # fallback

        # Search each topic word, collect candidates
        topic_words.first(3).each do |word|
          # Build pattern with concept synonyms + hyphen-aware boundaries
          terms = [word]
          terms.concat(CONCEPT_SYNONYMS[word]) if CONCEPT_SYNONYMS.key?(word)
          terms.uniq!
          combined = terms.map { |t|
            escaped = Regexp.escape(t)
            p = conn.quote("(^|[^a-zA-Z-])#{escaped}([^a-zA-Z-]|$)")
            "primary_gloss ~* #{p}"
          }.join(" OR ")

          hebrew = find_candidates(combined, conn, HEBREW_LANGS)
          greek  = find_candidates(combined, conn, GREEK_LANGS)

          # Topic words get more sidebar slots than person names/verbs
          slots = topic_words.include?(word) ? 2 : 1
          top_he = pick_top(hebrew, word, slots)
          top_gr = pick_top(greek, word, slots)

          all_hebrew.concat(top_he)
          all_greek.concat(top_gr)
        end

        # Deduplicate by lemma id
        all_hebrew.uniq! { |l| l.id }
        all_greek.uniq! { |l| l.id }

        return nil if all_hebrew.empty? && all_greek.empty?

        format_entries = ->(list) {
          list.map { |l|
            {
              id: l.id,
              lemma: l.lemma,
              normalized: l.normalized,
              transliteration: l.transliteration,
              language: l.language,
              primary_gloss: l.primary_gloss,
              part_of_speech: l.part_of_speech,
              frequency: l.frequency
            }
          }
        }

        {
          hebrew: format_entries.(all_hebrew.first(MAX_PER_LANGUAGE)),
          greek: format_entries.(all_greek.first(MAX_PER_LANGUAGE))
        }
      end

      def find_candidates(gloss_condition, conn, languages)
        sanitized = conn.quote(@query)

        # Pass 1: word-boundary match on primary_gloss (only attested lemmas).
        # `lemmas.frequency` is a denormalized count of occurrences in `words`
        # — we use it for ordering instead of recomputing per-row via
        # `(SELECT COUNT(*) FROM words WHERE lemma_id = lemmas.id)`, which
        # was previously the dominant cost (>1s on text searches). The
        # frequency column may drift after lemma cleanups; refresh it via
        # `rake lemmas:refresh_frequency` periodically.
        results = Lemma
          .where(Arel.sql("(#{gloss_condition})"))
          .where(language: languages)
          .where("frequency > 0")
          .order(frequency: :desc)
          .limit(15)
          .to_a

        # Pass 2: FTS on primary_gloss (stemmed — "help" matches "helping", "helper")
        if results.size < 5
          tsvector = "to_tsvector('english', COALESCE(primary_gloss, ''))"
          tsquery = "websearch_to_tsquery('english', #{sanitized})"
          fts_results = Lemma
            .where("#{tsvector} @@ #{tsquery}")
            .where(language: languages)
            .where("frequency > 0")
            .where.not(id: results.map(&:id))
            .order(frequency: :desc)
            .limit(10)
            .to_a
          results.concat(fts_results)
        end

        # Pass 3: FTS on senses (the structured definition text).
        # Only include results whose primary_gloss is a common word
        # (not a proper name — those have capitalized glosses).
        if results.size < 5
          senses_tsvector = "to_tsvector('english', COALESCE(senses::text, ''))"
          tsquery = "websearch_to_tsquery('english', #{sanitized})"
          senses_results = Lemma
            .where("#{senses_tsvector} @@ #{tsquery}")
            .where(language: languages)
            .where("frequency > 0")
            .where("primary_gloss !~ '^[A-Z]'")  # exclude proper names
            .where.not(id: results.map(&:id))
            .order(frequency: :desc)
            .limit(5)
            .to_a
          results.concat(senses_results)
        end

        results
      end

      # Pick the top N candidates, preferring diversity of part_of_speech.
      # If we have both a noun and a verb that match well, show both
      # rather than two verbs.
      def pick_top(candidates, query, n)
        return [] if candidates.empty?

        # Score against the original query AND any concept synonyms,
        # taking the best score. This ensures torah (glossed "instruction")
        # scores well when the user searches "law".
        concept_terms = CONCEPT_SYNONYMS.fetch(query.downcase, [])
        scored = candidates.map { |l|
          direct_score = gloss_score(l, query)
          # For concept synonyms: score higher if the synonym IS the primary
          # meaning (short gloss), lower if buried in a compound gloss.
          # "instruction" as entire gloss → 95. "to take; teaching" → 70.
          syn_scores = concept_terms.map { |syn|
            s = gloss_score(l, syn)
            next 0 if s < 30  # no match
            gloss = l.primary_gloss.to_s
            # Reward short/focused glosses where the synonym is prominent
            gloss_terms = gloss.split(/[;,]/).size
            if s >= 90 && gloss_terms <= 3
              95  # synonym is a primary meaning
            elsif s >= 60
              [85 - (gloss_terms * 2), 60].max  # penalize compound glosses
            else
              0
            end
          }
          best_score = ([direct_score] + syn_scores).max
          [l, best_score, l.frequency.to_i]
        }

        # Sort by score tier (bucket scores within 15 points of each other),
        # then by word count within tier. This ensures רֵאשִׁית (score 90,
        # freq 48) ranks above רִאשָׁה (score 100, freq 1) because they're
        # in the same tier but reshit is far more prominent.
        top_score = scored.map { |_, s, _| s }.max
        scored.sort_by! { |_, score, wc|
          tier = ((top_score - score) / 20.0).floor  # 0 = top tier, 1 = next, etc.
          [tier, -wc]
        }

        min_score = [top_score * 0.5, 10].max
        viable = scored.select { |_, score, _| score >= min_score }

        selected = []
        seen_pos = Set.new

        # First pass: pick top-tier candidates by score, then diversify
        # POS only for lower tiers. This ensures "law" shows torah+choq+mitsvah
        # (all nouns) rather than choq+chaqah(verb)+qayyam(adj).
        top_tier_score = viable.first&.at(1) || 0
        viable.each do |lemma, score, wc|
          pos = lemma.part_of_speech.to_s
          in_top_tier = (top_tier_score - score) < 20
          # In the top tier, take candidates regardless of POS
          # In lower tiers, prefer unseen POS for diversity
          if in_top_tier || !seen_pos.include?(pos)
            selected << lemma
            seen_pos << pos
          end
          break if selected.size >= n
        end

        # Second pass: fill remaining slots with highest-scoring candidates
        if selected.size < n
          viable.each do |lemma, _, _|
            next if selected.include?(lemma)
            selected << lemma
            break if selected.size >= n
          end
        end

        selected
      end

      def gloss_score(lemma, query)
        gloss = lemma.primary_gloss.to_s.downcase
        return 0 if gloss.blank?

        q = query.downcase

        # Best: gloss IS the query or starts with it
        return 100 if gloss == q || gloss.start_with?("#{q}:") || gloss.start_with?("#{q};") || gloss.start_with?("#{q}/") || gloss.start_with?("#{q},") || gloss.start_with?("#{q} ")

        # Very good: query is one of the delimited gloss terms.
        # STEP glosses use "sense: translation" format (e.g., "first: beginning").
        # Split on ; , / and also extract the part after : in each term.
        terms = gloss.split(/[;,\/]/).flat_map { |t|
          t = t.strip
          parts = t.split(":", 2).map(&:strip)
          parts.size > 1 ? [t, parts.last] : [t]
        }
        if terms.any? { |t| t == q || t.start_with?("#{q} ") || t.start_with?("#{q}:") }
          return 90
        end

        # Good: query appears as a word in the gloss
        if gloss.match?(/(?:^|[^a-z])#{Regexp.escape(q)}(?:[^a-z]|$)/)
          pos = gloss.index(/(?:^|[^a-z])#{Regexp.escape(q)}/)
          return 60 - [pos.to_i, 30].min
        end

        # Weak: senses/FTS only
        10
      end
    end
  end
end
