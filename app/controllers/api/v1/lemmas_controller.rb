module Api
  module V1
    class LemmasController < BaseController
      # GET /api/v1/lemmas?q=agape&language=grc&limit=25
      # Search by gloss, transliteration, normalized form, or Strong's number.
      def index
        q = params[:q].to_s.strip
        render json: { error: "query required" }, status: :bad_request and return if q.blank?

        limit = [[params.fetch(:limit, 25).to_i, 1].max, 100].min
        page  = [params.fetch(:page, 1).to_i, 1].max
        offset = (page - 1) * limit

        base = Lemma.where("frequency > 0")
        base = base.for_language(params[:language]) if params[:language].present?

        # Detect Strong's number query (H1234, G5678)
        if q.match?(/\A[HG]\d{1,5}\z/i)
          lemma_ids = Word.where("strongs_number ILIKE ?", q).distinct.pluck(:lemma_id).compact
          results = base.where(id: lemma_ids).order(frequency: :desc)
        else
          safe_q = ApplicationRecord.sanitize_sql_like(q)
          results = base.where(
            "primary_gloss ILIKE :like OR transliteration ILIKE :like OR normalized ILIKE :like OR lemma ILIKE :like",
            like: "%#{safe_q}%"
          ).order(
            Arel.sql(<<~SQL.squish)
              CASE
                WHEN primary_gloss ILIKE #{Lemma.connection.quote(q)} THEN 0
                WHEN transliteration ILIKE #{Lemma.connection.quote(q)} THEN 1
                WHEN primary_gloss ILIKE #{Lemma.connection.quote("#{safe_q}%")} THEN 2
                WHEN transliteration ILIKE #{Lemma.connection.quote("#{safe_q}%")} THEN 3
                ELSE 4
              END, frequency DESC
            SQL
          )
        end

        total = results.count
        page_results = results.offset(offset).limit(limit)

        render json: {
          query: q,
          count: total,
          page: page,
          per_page: limit,
          total_pages: (total.to_f / limit).ceil,
          results: page_results.map { |l| lemma_summary(l) }
        }
      end

      # GET /api/v1/lemmas/:id
      def show
        lemma = Lemma.find(params[:id])

        # Gather Strong's numbers associated with this lemma
        strongs = Word.where(lemma_id: lemma.id)
                      .where.not(strongs_number: [nil, ""])
                      .distinct
                      .pluck(:strongs_number)

        # Related lemmas
        related = if lemma.related_lemma_ids.present?
          Lemma.where(id: lemma.related_lemma_ids).map { |l| lemma_summary(l) }
        else
          []
        end

        render json: lemma_detail(lemma).merge(
          strongs_numbers: strongs,
          related_lemmas: related
        )
      end

      # GET /api/v1/lemmas/strong/:number
      # Resolve a Strong's number to its lemma(s).
      def strong
        number = params[:number].to_s.strip.upcase
        unless number.match?(/\A[HG]\d{1,5}\z/)
          render json: { error: "invalid Strong's number — expected H1234 or G5678" }, status: :bad_request
          return
        end

        lemma_ids = Word.where(strongs_number: number).distinct.pluck(:lemma_id).compact
        raise ActiveRecord::RecordNotFound if lemma_ids.empty?

        lemmas = Lemma.where(id: lemma_ids).order(frequency: :desc)
        render json: {
          strongs_number: number,
          lemmas: lemmas.map { |l| lemma_detail(l) }
        }
      end

      private

      def lemma_summary(l)
        {
          id: l.id,
          lemma: l.lemma,
          normalized: l.normalized,
          language: l.language,
          part_of_speech: l.part_of_speech,
          primary_gloss: l.primary_gloss,
          transliteration: l.transliteration,
          frequency: l.frequency
        }
      end

      def lemma_detail(l)
        lemma_summary(l).merge(
          etymology: l.etymology,
          senses: l.senses,
          frequency_by_book: l.frequency_by_book,
          attested_period: l.attested_period
        )
      end
    end
  end
end
