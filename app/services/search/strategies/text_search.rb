module Search
  module Strategies
    class TextSearch
      DEFAULT_LIMIT = 25
      MAX_LIMIT = 200
      HEADLINE_MAX_WORDS = 35
      HEADLINE_MIN_WORDS = 15
      HEADLINE_MAX_FRAGMENTS = 3

      def initialize(query, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @query = query
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        tsquery = build_tsquery
        return empty_result if tsquery.blank?

        offset = (@page - 1) * @per_page

        base = WorkUnit
          .joins(:canonical_ref, :work)
          .where("work_units.body_tsvector @@ #{tsquery}")
          .includes(:canonical_ref, work: :license)

        base = apply_scope(base)

        total = base.count

        # Person-topic queries ("What did Jesus teach about forgiveness?")
        # benefit from OR logic from the start: the AND query requires
        # every word in each matching verse, but forgiveness-related
        # verses rarely also contain "Jesus" + "teach". Use OR and let
        # the ranking sort out relevance.
        if total < 5 && @query.include?(" ") && person_topic_query?
          or_tsquery = build_or_tsquery
          if or_tsquery
            or_base = WorkUnit
              .joins(:canonical_ref, :work)
              .where("work_units.body_tsvector @@ #{or_tsquery}")
              .includes(:canonical_ref, work: :license)
            or_base = apply_scope(or_base)
            or_total = or_base.count
            if or_total > total
              base = or_base
              total = or_total
              tsquery = or_tsquery
            end
          end
        # Fallback: if a multi-word AND query returns 0 results, retry
        # with OR logic so verses matching MOST content words are found.
        # "put on the whole armor of God" with AND fails if any word is
        # missing, but with OR it finds Eph 6:11 which has most of them.
        elsif total == 0 && @query.include?(" ")
          or_tsquery = build_or_tsquery
          if or_tsquery
            base = WorkUnit
              .joins(:canonical_ref, :work)
              .where("work_units.body_tsvector @@ #{or_tsquery}")
              .includes(:canonical_ref, work: :license)
            base = apply_scope(base)
            total = base.count
            tsquery = or_tsquery
          end
        end

        # Rank by FTS relevance, boosted by:
        # 1. Cross-reference density (precomputed xref_count)
        # 2. Exact phrase match bonus (for multi-word queries, verses
        #    containing the exact phrase rank much higher). Check both
        #    the original query and the synonym-expanded version so
        #    "honor thy father" matches "Honor your father" (BSB).
        conn = ApplicationRecord.connection
        sanitized_like = conn.quote("%#{ApplicationRecord.sanitize_sql_like(@query)}%")
        if @query.include?(" ")
          # Check the phrase against the body with punctuation stripped,
          # so "my God my God why have you forsaken me" matches
          # "My God, my God, why have You forsaken me?" in the body.
          # Also check the synonym-expanded version.
          stripped_body = "REGEXP_REPLACE(work_units.body, '[^a-zA-Z\\s]', '', 'g')"
          expanded_like = "('%' || expand_bible_synonyms(#{conn.quote(@query)}) || '%')"
          phrase_bonus = "CASE " \
                         "WHEN work_units.body ILIKE #{sanitized_like} THEN 10.0 " \
                         "WHEN #{stripped_body} ILIKE #{sanitized_like} THEN 10.0 " \
                         "WHEN #{stripped_body} ILIKE #{expanded_like} THEN 8.0 " \
                         "ELSE 1.0 END"
        else
          # For single-word queries, boost verses containing the exact word
          # (not just the stem). Use word-boundary matching (\y) so "Eve"
          # ranks above "even/evening/every" and "leviathan" above "Levi".
          escaped_word = ApplicationRecord.sanitize_sql_like(@query)
          word_like = conn.quote("%#{escaped_word}%")
          word_boundary = conn.quote("\\y#{escape_posix_regex(@query)}\\y")
          phrase_bonus = "CASE " \
                         "WHEN work_units.body ~* #{word_boundary} THEN 5.0 " \
                         "WHEN work_units.body ILIKE #{word_like} THEN 1.5 " \
                         "ELSE 1.0 END"
        end

        results = base
          .select(
            "work_units.*",
            "ts_rank(work_units.body_tsvector, #{tsquery}) * (1.0 + LN(1 + canonical_refs.xref_count)) * #{phrase_bonus} AS relevance",
            headline_select(tsquery)
          )
          .order(Arel.sql("relevance DESC, canonical_refs.ord ASC, works.slug ASC"))
          .offset(offset)
          .limit(@per_page)
          .map { |wu| format_result(wu) }

        facets = compute_facets(base)

        ResultSet.new(
          results: results,
          query: @query,
          query_type: :text,
          total_count: total,
          facets: facets,
          page: @page,
          per_page: @per_page
        )
      rescue ActiveRecord::StatementInvalid
        # Handle invalid regex patterns or other SQL errors gracefully
        # (e.g. user input containing POSIX regex metacharacters that slip
        # through escaping into a ~* operator).
        empty_result
      end

      private

      def build_tsquery
        sanitized = ApplicationRecord.connection.quote(@query)

        # Expand Bible-English synonyms (honour→honor, thy→your, hath→has)
        # before building the tsquery. This is a SQL function that does a
        # table lookup, so "honor thy father" becomes "honor your father"
        # which then matches KJV's "Honour thy father" via stemming.
        expanded = "expand_bible_synonyms(#{sanitized})"

        # Use websearch_to_tsquery which handles boolean operators naturally.
        # Search against both English (stemmed) and simple (exact) configs,
        # OR them together so "beginning" matches English works via stemming
        # and Hebrew/Greek via exact token match.
        # We search with BOTH the original query and the synonym-expanded
        # version, so exact matches still rank highest.
        "(websearch_to_tsquery('scriptorium_english', #{expanded}) || " \
          "websearch_to_tsquery('scriptorium_english', #{sanitized}) || " \
          "websearch_to_tsquery('scriptorium_simple', #{sanitized}))"
      end

      # Fallback: convert the AND-based tsquery to OR-based so that
      # verses matching MOST content words still appear. Uses the
      # synonym-expanded query split into individual OR terms.
      def build_or_tsquery
        conn = ApplicationRecord.connection
        sanitized = conn.quote(@query)
        expanded = conn.select_value("SELECT expand_bible_synonyms(#{sanitized})")
        words = expanded.split(/\s+/).reject { |w| w.length < 3 }
        return nil if words.empty?

        # Build an OR tsquery from individual words
        terms = words.map { |w| "plainto_tsquery('scriptorium_english', #{conn.quote(w)})" }
        "(#{terms.join(' || ')})"
      end

      def headline_select(tsquery)
        sanitized = ApplicationRecord.connection.quote(@query)
        # Use dollar-quoting for the options string to avoid issues with
        # angle brackets in StartSel/StopSel being parsed as SQL operators.
        Arel.sql(
          "ts_headline('scriptorium_english', COALESCE(work_units.body, ''), " \
            "websearch_to_tsquery('scriptorium_english', #{sanitized}), " \
            "$$StartSel=<mark>, StopSel=</mark>, MaxWords=#{HEADLINE_MAX_WORDS}, " \
            "MinWords=#{HEADLINE_MIN_WORDS}, MaxFragments=#{HEADLINE_MAX_FRAGMENTS}$$) AS headline"
        )
      end

      def apply_scope(base)
        if @scope.is_a?(Hash)
          base = base.where(works: { slug: @scope[:work] }) if @scope[:work].present?
          base = base.where(works: { language: @scope[:language] }) if @scope[:language].present?
          base = base.where(works: { language: @scope[:languages] }) if @scope[:languages].is_a?(Array)
          base = base.where(works: { work_type: @scope[:work_types] }) if @scope[:work_types].present?

          # Section filter (was "testament")
          if @scope[:sections].is_a?(Array) && @scope[:sections].any?
            base = base.joins(canonical_ref: :canonical_work)
                       .where(canonical_works: { testament: @scope[:sections] })
          elsif @scope[:testament].present?
            base = base.joins(canonical_ref: :canonical_work)
                       .where(canonical_works: { testament: @scope[:testament] })
          end

          # Tradition filter (searches works.traditions array)
          if @scope[:traditions].is_a?(Array) && @scope[:traditions].any?
            base = base.where("works.traditions && ARRAY[?]::varchar[]", @scope[:traditions])
          end

          # Book filter (canonical_work slug)
          if @scope[:book].present?
            base = base.joins(canonical_ref: :canonical_work)
                       .where(canonical_works: { book_key: @scope[:book] })
          end
        end
        base
      end

      def compute_facets(base)
        {
          works: base.group("works.slug", "works.title").count
                     .map { |(slug, title), count| { slug: slug, title: title, count: count } }
                     .sort_by { |f| -f[:count] },
          languages: base.group("works.language").count
                         .map { |lang, count| { language: lang, count: count } }
                         .sort_by { |f| -f[:count] }
        }
      end

      def format_result(wu)
        raw_headline = wu.respond_to?(:headline) ? wu.headline : wu.body

        {
          id: wu.id,
          work_slug: wu.work.slug,
          work_title: wu.work.title,
          language: wu.work.language,
          canonical_ref_id: wu.canonical_ref_id,
          citation: wu.canonical_ref.sbl_citation || wu.canonical_ref.display_label,
          hierarchy: wu.canonical_ref.hierarchy,
          body: wu.body,
          headline: enhance_headline(raw_headline, wu.body),
          relevance: wu.respond_to?(:relevance) ? wu.relevance : 0,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key
        }
      end

      # For multi-word queries, ts_headline only highlights individual
      # stemmed tokens (skipping stopwords). This post-processes the
      # headline to highlight the full matching phrase when the body
      # contains it, so "my God, my God, why have You forsaken me"
      # gets the whole phrase highlighted, not just "God" and "forsaken".
      def enhance_headline(headline, body)
        return headline unless @query.include?(" ") && body.present?

        # Try to find the query phrase (case-insensitive, punctuation-tolerant)
        # in the body and wrap it with <mark> tags.
        pattern = @query.split(/\s+/).map { |w| Regexp.escape(w) }.join('[^a-zA-Z]*\s*')
        if body.match?(Regexp.new(pattern, Regexp::IGNORECASE))
          # Replace in the body directly (not the ts_headline output)
          body.gsub(Regexp.new("(#{pattern})", Regexp::IGNORECASE), '<mark>\1</mark>')
        else
          headline
        end
      end

      # Escape POSIX regex metacharacters so user input can be used safely
      # in Postgres ~ / ~* operators without triggering PG::InvalidRegularExpression.
      def escape_posix_regex(str)
        str.gsub(/([.\\+*?\[\](){}|^$])/, '\\\\\1')
      end

      # Detect person-topic queries like "What did Jesus teach about
      # forgiveness?" or "Moses and the burning bush". These combine a
      # biblical figure with a topical concept and benefit from OR-based
      # FTS since the person and topic rarely co-occur in the same verse.
      PERSON_NAMES = %w[
        jesus christ yeshua paul peter john james timothy titus
        barnabas silas luke stephen philip apollos nicodemus lazarus
        martha pilate herod moses abraham david solomon samuel elijah
        elisha isaiah jeremiah ezekiel daniel noah jacob isaac joseph
        joshua gideon samson ruth esther nehemiah ezra job jonah
        adam eve cain abel sarah rebekah rachel saul bathsheba goliath
        pharaoh balaam deborah
      ].to_set.freeze

      TOPIC_STOP_WORDS = %w[
        what where when who why how does did do is are was were
        the a an of in to for and or but with about from by
        that this these those it its they them their
        can could should would will shall may might
        bible say says said tell tells told teach teaches taught
        verse verses passage passages scripture scriptures
        talk talks about regarding concerning wrote write
      ].to_set.freeze

      def person_topic_query?
        words = @query.downcase.gsub(/[?!.,;:'"]/, "").split
        has_person = words.any? { |w| PERSON_NAMES.include?(w) }
        topic_words = words.reject { |w| TOPIC_STOP_WORDS.include?(w) || PERSON_NAMES.include?(w) }
        has_person && topic_words.any?
      end

      def empty_result
        ResultSet.new(query: @query, query_type: :text)
      end
    end
  end
end
