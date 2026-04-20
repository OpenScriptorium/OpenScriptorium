module Search
  module Strategies
    class ProximitySearch
      # Finds verses where two terms both appear — either in the same verse
      # or within N verses of each other. Uses body_tsvector (GIN-indexed)
      # for fast matching instead of ILIKE, which avoids full-table scans
      # and substring false positives ("sin" no longer matches "Sinai").

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100
      MAX_DISTANCE = 20
      TIMEOUT_MS = 10_000

      def initialize(term_a, term_b, distance: 5, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @term_a = term_a.to_s.strip
        @term_b = term_b.to_s.strip
        @distance = [[distance.to_i, 0].max, MAX_DISTANCE].min
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        return empty_result if @term_a.blank? || @term_b.blank?

        conn = ApplicationRecord.connection
        offset = (@page - 1) * @per_page

        tsquery_a = "plainto_tsquery('scriptorium_english', #{conn.quote(@term_a)})"
        tsquery_b = "plainto_tsquery('scriptorium_english', #{conn.quote(@term_b)})"

        # Same-verse matches: both terms in the same work_unit via tsvector
        base = WorkUnit
          .joins(:canonical_ref, :work)
          .where("work_units.body_tsvector @@ #{tsquery_a}")
          .where("work_units.body_tsvector @@ #{tsquery_b}")
          .includes(:canonical_ref, work: :license)

        base = apply_scope(base)

        if @distance > 0
          # Cross-verse matches: term_a in one verse, term_b in a nearby verse
          cross_verse_ids = find_cross_verse_matches(tsquery_a, tsquery_b, conn)
          if cross_verse_ids.any?
            cross = WorkUnit.joins(:canonical_ref, :work)
                            .where(id: cross_verse_ids)
            cross = apply_scope(cross)
            base = base.or(cross)
          end
        end

        total = base.count
        results = base
          .order("canonical_refs.ord")
          .offset(offset)
          .limit(@per_page)
          .map { |wu| format_result(wu) }

        ResultSet.new(
          results: results,
          query: "#{@term_a} NEAR/#{@distance} #{@term_b}",
          query_type: :proximity,
          total_count: total,
          page: @page,
          per_page: @per_page
        )
      rescue ActiveRecord::StatementInvalid => e
        # Handle timeouts or bad queries gracefully
        empty_result
      end

      private

      def find_cross_verse_matches(tsquery_a, tsquery_b, conn)
        scope_sql = build_scope_sql(conn)

        sql = <<~SQL
          SELECT DISTINCT a.id
          FROM work_units a
          JOIN canonical_refs cr_a ON cr_a.id = a.canonical_ref_id
          JOIN works w ON w.id = a.work_id
          WHERE a.body_tsvector @@ #{tsquery_a}
            #{scope_sql}
            AND EXISTS (
              SELECT 1 FROM work_units b
              JOIN canonical_refs cr_b ON cr_b.id = b.canonical_ref_id
              WHERE b.work_id = a.work_id
                AND b.id != a.id
                AND b.body_tsvector @@ #{tsquery_b}
                AND ABS(cr_a.ord - cr_b.ord) <= #{@distance.to_i}
            )
          LIMIT 500
        SQL

        conn.select_values(sql)
      rescue ActiveRecord::StatementInvalid
        []
      end

      def build_scope_sql(conn)
        parts = []
        if @scope.is_a?(Hash)
          if @scope[:work].present?
            work_id = Work.where(slug: @scope[:work]).pick(:id)
            parts << "AND a.work_id = #{work_id.to_i}" if work_id
          end
          if @scope[:work_types].is_a?(Array)
            types = @scope[:work_types].map { |t| conn.quote(t) }.join(", ")
            parts << "AND w.work_type IN (#{types})"
          end
          if @scope[:languages].is_a?(Array)
            langs = @scope[:languages].map { |l| conn.quote(l) }.join(", ")
            parts << "AND w.language IN (#{langs})"
          end
          if @scope[:language].present?
            parts << "AND w.language = #{conn.quote(@scope[:language])}"
          end
        end
        parts.join("\n")
      end

      def apply_scope(base)
        if @scope.is_a?(Hash)
          base = base.where(works: { slug: @scope[:work] }) if @scope[:work].present?
          base = base.where(works: { work_type: @scope[:work_types] }) if @scope[:work_types].is_a?(Array)
          base = base.where(works: { language: @scope[:language] }) if @scope[:language].present?
          base = base.where(works: { language: @scope[:languages] }) if @scope[:languages].is_a?(Array)
        end
        base
      end

      def format_result(wu)
        {
          id: wu.id,
          work_slug: wu.work.slug,
          work_title: wu.work.title,
          language: wu.work.language,
          canonical_ref_id: wu.canonical_ref_id,
          citation: wu.canonical_ref.sbl_citation || wu.canonical_ref.display_label,
          hierarchy: wu.canonical_ref.hierarchy,
          body: wu.body,
          headline: highlight_terms(wu.body),
          relevance: 1.0,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key
        }
      end

      def highlight_terms(body)
        return body if body.blank?
        text = body.dup
        [@term_a, @term_b].each do |term|
          text.gsub!(/(#{Regexp.escape(term)})/i, '<mark>\1</mark>')
        end
        text
      end

      def empty_result
        ResultSet.new(query: "#{@term_a} NEAR/#{@distance} #{@term_b}", query_type: :proximity)
      end
    end
  end
end
