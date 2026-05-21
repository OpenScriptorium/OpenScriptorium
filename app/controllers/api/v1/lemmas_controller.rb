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

        # Gather Strong's numbers associated with this lemma, collapsed
        # to one canonical "G####" / "H####" per number — see Strongs
        # for the storage-variant background.
        raw_strongs_counts = Word.where(lemma_id: lemma.id)
                                 .where.not(strongs_number: [nil, ""])
                                 .group(:strongs_number)
                                 .count
        strongs = Strongs.normalize_set_with_counts(raw_strongs_counts, language: lemma.language)

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
          primary_gloss: lexicon_or_short_gloss(l),
          transliteration: l.transliteration,
          frequency: l.frequency
        }
      end

      # Gloss-selection priority for the popover:
      #   1. lemma.primary_gloss — curated by step_lexicon from STEPBible
      #      TBESG/TBESH plus the fix_parenthetical_glosses and
      #      prefer_step_glosses cleanup passes. Authoritative for
      #      biblical Hebrew/Greek.
      #   2. BDB short summary — clean, biblical-Hebrew-specific.
      #   3. LSJ summary — last resort. LSJ covers all classical Greek
      #      including Homeric senses that don't fit NT lemmas (it
      #      ships "lay" for λέγω before "to say"; "abode" before
      #      "house" for οἶκος). Only use it when nothing else exists.
      def lexicon_or_short_gloss(l)
        if l.primary_gloss.present? && !l.primary_gloss.start_with?("(")
          return short_gloss(l.primary_gloss)
        end
        priority = %w[BDB LSJ Thayer]
        entries = LexiconEntry.where(lemma_id: l.id, source: priority)
                              .where.not(summary_gloss: [nil, ""])
                              .pluck(:source, :summary_gloss)
        if (best = entries.min_by { |source, _| priority.index(source) || 99 })
          return truncate_gloss(best.last)
        end
        nil
      end

      def truncate_gloss(s)
        out = s.to_s.strip
        out.length > 80 ? "#{out[0..76].rstrip}…" : out
      end

      # Strong's-style primary_gloss values are often long lexicon dumps
      # ("the first, in place, time, order or rank (specifically, a
      # firstfruit) beginning, chief(-est)..."). The reader popover only
      # has room for a short phrase, and the long form reads as
      # disconnected from the translation the user is looking at. Trim
      # at the first parenthesis or semicolon, strip trailing
      # punctuation, cap at 80 chars.
      def short_gloss(s)
        return nil if s.blank?
        cleaned = s.to_s.strip
        cleaned = cleaned.split(/[(;]/).first.to_s.strip
        cleaned = cleaned.sub(/[,.;:\-]+\z/, "").strip
        return nil if cleaned.empty?
        cleaned = "#{cleaned[0..76].rstrip}…" if cleaned.length > 80
        cleaned
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
