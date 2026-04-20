module Api
  module V1
    class DiscourseController < BaseController
      # GET /api/v1/discourse/:work_slug/:book/:chapter
      # Returns participant tracking data for a chapter
      def show
        work = Work.find_by!(slug: params[:work_slug])

        # Find all work_units in this chapter
        chapter = params[:chapter].to_i
        work_units = WorkUnit.joins(:canonical_ref)
                             .where(work_id: work.id)
                             .where("canonical_refs.hierarchy[1] = ?", chapter)
                             .where("canonical_refs.sbl_citation LIKE ?", "#{params[:book]} %")
                             .order("canonical_refs.ord")
                             .includes(:canonical_ref)

        raise ActiveRecord::RecordNotFound if work_units.empty?

        # Get all participant references for these verses
        wu_ids = work_units.pluck(:id)
        refs = ParticipantReference.where(work_unit_id: wu_ids)
                                   .includes(:word, :referent_word)

        # Build participant chains
        participants = build_participant_data(work_units, refs)

        # Detect chiasms if requested
        chiasms = nil
        if params[:chiasms] == "true"
          cr = work_units.first.canonical_ref
          cw_id = cr.canonical_work_id
          ords = work_units.map { |wu| wu.canonical_ref.ord }
          chiasms = ChiasmDetector.new.detect(
            canonical_work_id: cw_id,
            start_ord: ords.min,
            end_ord: ords.max
          )
        end

        render json: {
          work: work.slug,
          chapter: "#{params[:book]} #{chapter}",
          verses: build_verse_data(work_units, refs),
          participants: participants,
          chiasms: chiasms
        }
      end

      private

      def build_verse_data(work_units, refs)
        refs_by_wu = refs.group_by(&:work_unit_id)

        work_units.map do |wu|
          verse_refs = refs_by_wu[wu.id] || []
          {
            citation: wu.canonical_ref.sbl_citation,
            agents: verse_refs.select { |r| r.ref_type == "frame_a0" }.filter_map { |r|
              r.referent_word ? { surface: r.referent_word.surface, lemma: r.referent_word.lemma&.normalized } : nil
            }.uniq,
            patients: verse_refs.select { |r| r.ref_type == "frame_a1" }.filter_map { |r|
              r.referent_word ? { surface: r.referent_word.surface, lemma: r.referent_word.lemma&.normalized } : nil
            }.uniq,
            subjects: verse_refs.select { |r| r.ref_type == "subject" }.filter_map { |r|
              r.referent_word ? { surface: r.referent_word.surface, lemma: r.referent_word.lemma&.normalized } : nil
            }.uniq,
            coreferences: verse_refs.select { |r| r.ref_type == "participant" }.filter_map { |r|
              next nil unless r.referent_word
              { pronoun: r.word&.surface, referent: r.referent_word.surface, referent_lemma: r.referent_word.lemma&.normalized }
            }
          }
        end
      end

      def build_participant_data(work_units, refs)
        # Track unique participants across the chapter
        participant_map = Hash.new { |h, k| h[k] = { verses: [], roles: Set.new, count: 0 } }

        refs.each do |ref|
          next unless ref.referent_word
          lemma = ref.referent_word.lemma&.normalized
          next unless lemma

          citation = WorkUnit.find(ref.work_unit_id).canonical_ref.sbl_citation rescue next
          entry = participant_map[lemma]
          entry[:surface] ||= ref.referent_word.surface
          entry[:gloss] ||= ref.referent_word.lemma&.primary_gloss&.split(";")&.first&.strip
          entry[:verses] << citation unless entry[:verses].include?(citation)
          entry[:roles] << ref.ref_type
          entry[:count] += 1
        end

        # Return top participants sorted by frequency
        participant_map.map { |lemma, data|
          {
            lemma: lemma,
            surface: data[:surface],
            gloss: data[:gloss],
            verse_count: data[:verses].size,
            reference_count: data[:count],
            roles: data[:roles].to_a,
            verses: data[:verses]
          }
        }.sort_by { |p| -p[:reference_count] }.first(20)
      end
    end
  end
end
