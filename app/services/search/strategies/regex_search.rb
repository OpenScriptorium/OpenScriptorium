module Search
  module Strategies
    class RegexSearch
      # Regex pattern search using Postgres ~* (case-insensitive).
      # Without a work scope, searches default scripture types with a timeout.

      DEFAULT_LIMIT = 25
      MAX_LIMIT = 100
      TIMEOUT_MS = 5_000

      def initialize(query, scope: nil, page: 1, per_page: DEFAULT_LIMIT)
        @query = query.to_s.strip
        @scope = scope
        @page = [page.to_i, 1].max
        @per_page = [[per_page.to_i, 1].max, MAX_LIMIT].min
      end

      def call
        return empty_result if @query.blank?

        # Translate common PCRE shortcuts to POSIX equivalents since
        # Postgres uses POSIX extended regex, not PCRE.
        pg_pattern = pcre_to_posix(@query)

        offset = (@page - 1) * @per_page

        begin
          ApplicationRecord.transaction do
            ApplicationRecord.connection.execute("SET LOCAL statement_timeout = '#{TIMEOUT_MS}ms'")

            base = WorkUnit
              .joins(:canonical_ref, :work)
              .where("work_units.body ~* ?", pg_pattern)
              .includes(:canonical_ref, work: :license)

            base = apply_scope(base)

            total = base.count

            work_units = base
              .order("canonical_refs.ord")
              .offset(offset)
              .limit(@per_page)

            results = work_units.map { |wu| format_result(wu) }

            return ResultSet.new(
              results: results,
              query: @query,
              query_type: :regex,
              total_count: total,
              page: @page,
              per_page: @per_page
            )
          end
        rescue ActiveRecord::StatementInvalid => e
          if e.message.include?("cancel") || e.message.include?("timeout")
            return ResultSet.new(
              query: @query, query_type: :regex, results: [], total_count: 0
            )
          end
          # Invalid regex syntax (e.g. unbalanced braces, bad quantifiers) —
          # return empty results rather than crashing.
          return empty_result
        end
      end

      private

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
          headline: highlight_matches(wu.body),
          relevance: 1.0,
          license: wu.work.license.name,
          book_slug: wu.canonical_ref.canonical_work.book_key
        }
      end

      def highlight_matches(body)
        return body if body.blank?
        body.gsub(/(#{@query})/i, '<mark>\1</mark>')
      rescue RegexpError
        body
      end

      def apply_scope(base)
        if @scope.is_a?(Hash)
          base = base.where(works: { slug: @scope[:work] }) if @scope[:work].present?
          base = base.where(works: { language: @scope[:language] }) if @scope[:language].present?
          base = base.where(works: { language: @scope[:languages] }) if @scope[:languages].is_a?(Array)
          base = base.where(works: { work_type: @scope[:work_types] }) if @scope[:work_types].is_a?(Array)
        end
        base
      end

      # Translate common Perl/Ruby regex shortcuts to Postgres POSIX equivalents.
      def pcre_to_posix(pattern)
        pattern
          .gsub('\d', '[[:digit:]]')
          .gsub('\D', '[^[:digit:]]')
          .gsub('\w', '[[:alnum:]_]')
          .gsub('\W', '[^[:alnum:]_]')
          .gsub('\s', '[[:space:]]')
          .gsub('\S', '[^[:space:]]')
          .gsub('\b', '\\y')  # Postgres word boundary
      end

      def empty_result
        ResultSet.new(query: @query, query_type: :regex)
      end
    end
  end
end
