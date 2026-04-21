module Search
  module Strategies
    class SyntaxSearch
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      ROLE_LABELS = SyntaxNode::ROLE_LABELS

      def initialize(query, extra: {}, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @query = query
        @roles = extra[:roles] || {}
        @clause_type = extra[:clause_type]
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        return empty_result if @roles.empty? && @clause_type.nil?

        offset = (@page - 1) * @per_page

        # Build the query: find work_units where each role+lemma pair is satisfied
        base = build_query
        total = base.count
        work_units = base.order("canonical_refs.ord").offset(offset).limit(@per_page)

        results = work_units.map { |wu| format_result(wu) }

        ResultSet.new(
          results: results,
          query: @query,
          query_type: :syntax,
          total_count: total,
          page: @page,
          per_page: @per_page
        )
      end

      private

      def build_query
        base = WorkUnit
          .joins(:canonical_ref, :work)
          .includes(:canonical_ref, work: :license)

        # Apply scope
        base = apply_scope(base)

        # For each role+lemma pair, add an EXISTS constraint.
        # Search both word-level roles AND syntax_node roles (which have
        # much better coverage for subjects/objects/predicates).
        @roles.each_with_index do |(role, lemma), idx|
          normalized = strip_diacritics(lemma)
          gloss = lemma.gsub(/[^a-zA-Z\s]/, "") if lemma.match?(/\A[a-zA-Z\s]+\z/)

          # For verb queries, match by POS (morph_code starts with V) since
          # many verbs don't have explicit role markers in Macula
          role_condition = if role == "v"
            "(w#{idx}.role = 'v' OR sn#{idx}.role = 'v' OR sn#{idx}.role = 'p' OR w#{idx}.morph_code LIKE 'V%')"
          else
            "(w#{idx}.role = '#{role}' OR sn#{idx}.role = '#{role}')"
          end

          if gloss
            # English gloss search: match primary_gloss via ILIKE, use
            # FTS for word-stem matching ("speak" finds "speaks"/"spoken"),
            # and search the senses jsonb array for broader coverage.
            base = base.where(
              "EXISTS (SELECT 1 FROM words w#{idx}
               JOIN lemmas l#{idx} ON l#{idx}.id = w#{idx}.lemma_id
               LEFT JOIN syntax_nodes sn#{idx} ON sn#{idx}.id = w#{idx}.syntax_node_id
               WHERE w#{idx}.work_unit_id = work_units.id
                 AND #{role_condition}
                 AND (l#{idx}.primary_gloss ILIKE ?
                      OR to_tsvector('english', COALESCE(l#{idx}.primary_gloss, '')) @@ plainto_tsquery('english', ?)
                      OR l#{idx}.senses::text ILIKE ?))",
              "%#{gloss}%", gloss, "%#{gloss}%"
            )
          else
            base = base.where(
              "EXISTS (SELECT 1 FROM words w#{idx}
               JOIN lemmas l#{idx} ON l#{idx}.id = w#{idx}.lemma_id
               LEFT JOIN syntax_nodes sn#{idx} ON sn#{idx}.id = w#{idx}.syntax_node_id
               WHERE w#{idx}.work_unit_id = work_units.id
                 AND #{role_condition}
                 AND (l#{idx}.lemma = ? OR l#{idx}.normalized ILIKE ?))",
              lemma, normalized
            )
          end
        end

        # Clause type filter — the CLAUSE_ALIASES hash from QueryClassifier
        # uses several detection strategies depending on the Macula data.
        if @clause_type.is_a?(Hash)
          base = apply_clause_filter(base, @clause_type)
        elsif @clause_type.is_a?(Array) && @clause_type.any?
          # Legacy simple array format — try both rule and clause_type columns
          types = @clause_type.map { |t| ApplicationRecord.connection.quote(t) }.join(", ")
          base = base.where(
            "EXISTS (SELECT 1 FROM syntax_nodes clause_sn
             WHERE clause_sn.work_unit_id = work_units.id
               AND clause_sn.node_class IN ('cl', 'relp', 'wg')
               AND (clause_sn.rule IN (#{types}) OR clause_sn.clause_type IN (#{types})))"
          )
        end

        base.distinct
      end

      def apply_scope(base)
        if @scope.is_a?(Hash)
          base = base.where(works: { slug: @scope[:work] }) if @scope[:work].present?
          base = base.where(works: { language: @scope[:language] }) if @scope[:language].present?
          base = base.where(works: { language: @scope[:languages] }) if @scope[:languages].is_a?(Array)
          base = base.where(works: { work_type: @scope[:work_types] }) if @scope[:work_types].is_a?(Array)
        end
        # Default: only search works that have syntax data (Hebrew + Greek originals)
        unless @scope&.dig(:work).present?
          base = base.where(works: { slug: %w[wlc nestle1904] })
        end
        base
      end

      # Build clause-type filter SQL from a CLAUSE_ALIASES hash.
      # Strategies:
      #   :rule          — exact match on syntax_nodes.rule (IN list)
      #   :rule_pattern  — SQL LIKE pattern on syntax_nodes.rule
      #   :clause_type   — exact match on syntax_nodes.clause_type (Greek cltype)
      #   :node_class    — match on syntax_nodes.node_class
      #   :role          — match on syntax_nodes.role (e.g. "cond" for conditional)
      #   :word_morph    — clause contains a word whose morph_code LIKE pattern
      #   :word_morph_any — clause contains a word matching ANY of several morph patterns
      #   :word_class    — clause contains a word whose XML class matches (stored in notes)
      def apply_clause_filter(base, filter)
        conn = ApplicationRecord.connection

        # --- Syntax node level conditions (OR'd together) ---
        node_conditions = []

        if filter[:rule]
          quoted = filter[:rule].map { |r| conn.quote(r) }.join(", ")
          node_conditions << "clause_sn.rule IN (#{quoted})"
        end

        if filter[:rule_pattern]
          if filter[:rule_pattern].is_a?(Array)
            filter[:rule_pattern].each do |pat|
              node_conditions << "clause_sn.rule LIKE #{conn.quote(pat)}"
            end
          else
            node_conditions << "clause_sn.rule LIKE #{conn.quote(filter[:rule_pattern])}"
          end
        end

        if filter[:clause_type]
          quoted = filter[:clause_type].map { |t| conn.quote(t) }.join(", ")
          node_conditions << "clause_sn.clause_type IN (#{quoted})"
        end

        if filter[:node_class]
          quoted = filter[:node_class].map { |c| conn.quote(c) }.join(", ")
          node_conditions << "clause_sn.node_class IN (#{quoted})"
        end

        if filter[:role]
          quoted = filter[:role].map { |r| conn.quote(r) }.join(", ")
          node_conditions << "clause_sn.role IN (#{quoted})"
        end

        # Verb-slot detection for verbal clauses: matches clauses whose
        # rule contains a standalone V constituent (not ADV, not VC).
        # Restricted to node_class='cl' to avoid matching phrase rules.
        if filter[:has_verb_slot]
          node_conditions << "(clause_sn.node_class = 'cl' AND (clause_sn.rule LIKE 'V-%'
            OR clause_sn.rule LIKE '%-V-%'
            OR clause_sn.rule LIKE '%-V'
            OR clause_sn.rule = 'V2CL'))"
        end

        # No-verb-slot detection for nominal/verbless clauses: matches
        # clauses whose rule does not contain a standalone V or VC
        # (copula verb) constituent.  "V" as a verb slot appears as:
        # V-..., ...-V-..., ...-V, V2CL.  "VC" (copula) appears as:
        # VC-..., ...-VC-..., ...-VC.  Must not false-match on "ADV".
        # Restricted to node_class='cl' to avoid matching phrase-level
        # rules like NPofNP.
        if filter[:no_verb_slot]
          node_conditions << "(clause_sn.node_class = 'cl'
            AND clause_sn.rule IS NOT NULL
            AND clause_sn.rule NOT LIKE 'V-%'
            AND clause_sn.rule NOT LIKE '%-V-%'
            AND clause_sn.rule NOT LIKE '%-V'
            AND clause_sn.rule NOT LIKE 'V2CL'
            AND clause_sn.rule NOT LIKE 'VC-%'
            AND clause_sn.rule NOT LIKE '%-VC-%'
            AND clause_sn.rule NOT LIKE '%-VC')"
        end

        if node_conditions.any?
          clause_filter = node_conditions.join(" OR ")
          base = base.where(
            "EXISTS (SELECT 1 FROM syntax_nodes clause_sn
             WHERE clause_sn.work_unit_id = work_units.id
               AND clause_sn.node_class IN ('cl', 'relp', 'wg')
               AND (#{clause_filter}))"
          )
        end

        # --- Word-level morph detection (for narrative, imperative, etc.) ---
        if filter[:word_morph]
          base = base.where(
            "EXISTS (SELECT 1 FROM words cw
             WHERE cw.work_unit_id = work_units.id
               AND cw.morph_code LIKE ?)",
            filter[:word_morph]
          )
        end

        if filter[:word_morph_any]
          morph_conds = filter[:word_morph_any].map { "cw.morph_code LIKE #{conn.quote(_1)}" }
          base = base.where(
            "EXISTS (SELECT 1 FROM words cw
             WHERE cw.work_unit_id = work_units.id
               AND (#{morph_conds.join(' OR ')}))"
          )
        end

        # Word-class detection for interrogatives: Hebrew uses morph "Ti"
        # for interrogative particles (מָה ,הֲ ,לָמָּה etc.).
        if filter[:word_class] == "inrg"
          base = base.where(
            "EXISTS (SELECT 1 FROM words cw
             WHERE cw.work_unit_id = work_units.id
               AND cw.morph_code = 'Ti')"
          )
        end

        # Word-lemma detection: clause contains a word with one of the
        # given lemma values (e.g. conditional particles).
        if filter[:word_lemma_any]
          lemma_list = filter[:word_lemma_any].map { |l| conn.quote(l) }.join(", ")
          base = base.where(
            "EXISTS (SELECT 1 FROM words cw
             JOIN lemmas cl ON cl.id = cw.lemma_id
             WHERE cw.work_unit_id = work_units.id
               AND cl.lemma IN (#{lemma_list}))"
          )
        end

        # Clause-role detection: match syntax_nodes that are clauses
        # (node_class = 'cl') with a specific role.
        if filter[:clause_role]
          quoted = filter[:clause_role].map { |r| conn.quote(r) }.join(", ")
          base = base.where(
            "EXISTS (SELECT 1 FROM syntax_nodes csn
             WHERE csn.work_unit_id = work_units.id
               AND csn.node_class = 'cl'
               AND csn.role IN (#{quoted}))"
          )
        end

        base
      end

      def format_result(wu)
        # Find the matched words for highlighting
        matched_words = find_matched_words(wu)
        headline = highlight_matches(wu.body, matched_words)
        role_info = matched_words.map { |w| "#{ROLE_LABELS[w.role] || w.role}: #{w.surface}" }.join(" | ")

        {
          id: wu.id,
          work_slug: wu.work.slug,
          work_title: wu.work.title,
          language: wu.work.language,
          canonical_ref_id: wu.canonical_ref_id,
          citation: wu.canonical_ref.sbl_citation || wu.canonical_ref.display_label,
          hierarchy: wu.canonical_ref.hierarchy,
          body: wu.body,
          headline: headline,
          relevance: 1.0,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key,
          syntax_roles: role_info
        }
      end

      def find_matched_words(wu)
        words = []
        @roles.each do |role, lemma|
          normalized = strip_diacritics(lemma)
          gloss = lemma.gsub(/[^a-zA-Z\s]/, "") if lemma.match?(/\A[a-zA-Z\s]+\z/)

          base_scope = Word.joins(:lemma)
                          .left_joins(:syntax_node)
                          .where(work_unit_id: wu.id)

          # Role matching (mirrors build_query logic)
          if role == "v"
            base_scope = base_scope.where(
              "words.role = 'v' OR syntax_nodes.role = 'v' OR syntax_nodes.role = 'p' OR words.morph_code LIKE 'V%'"
            )
          else
            base_scope = base_scope.where(
              "words.role = ? OR syntax_nodes.role = ?", role, role
            )
          end

          w = if gloss
            base_scope.where(
              "lemmas.primary_gloss ILIKE ?
               OR to_tsvector('english', COALESCE(lemmas.primary_gloss, '')) @@ plainto_tsquery('english', ?)
               OR lemmas.senses::text ILIKE ?",
              "%#{gloss}%", gloss, "%#{gloss}%"
            ).first
          else
            base_scope.where(
              "lemmas.lemma = ? OR lemmas.normalized = ?", lemma, normalized
            ).first
          end
          words << w if w
        end
        words
      end

      def highlight_matches(body, words)
        return body if body.blank? || words.empty?
        result = body.dup
        words.each do |w|
          result.gsub!(/(#{Regexp.escape(w.surface)})/i, '<mark>\1</mark>')
        end
        result
      end

      def strip_diacritics(str)
        str.to_s
           .unicode_normalize(:nfd)
           .gsub(/[\u0300-\u036F\u0591-\u05BD\u05BF-\u05C7]/, "")
      end

      def empty_result
        ResultSet.new(query: @query, query_type: :syntax)
      end
    end
  end
end
