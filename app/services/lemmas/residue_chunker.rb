require "json"
require "fileutils"

module Lemmas
  # Walks el-koine Lemma rows that still lack a primary_gloss after
  # all other passes (LSJ exact, LSJ fallback, Hebrew cross-link, TBESG)
  # and writes them in chunks to disk, each token paired with a small
  # set of verse contexts. The chunks are the input to an editorial
  # review pass; the applier consumes the resulting per-chunk TSVs and
  # writes glosses back to the Lemma rows.
  #
  # Output layout:
  #   /tmp/gloss_chunks/chunk_NNN.json
  #
  # Each chunk file is a JSON array of objects shaped like:
  #   {
  #     "lemma_id": 12345,
  #     "lemma":    "Νωεμιν",
  #     "contexts": [
  #       {"ref": "Ruth 1:2", "text": "..."},
  #       {"ref": "Ruth 1:8", "text": "..."}
  #     ]
  #   }
  class ResidueChunker
    DEFAULT_DIR    = "/tmp/gloss_chunks"
    CHUNK_SIZE     = 200
    CONTEXTS_PER   = 2  # number of verse appearances to include per lemma

    attr_reader :stats

    def initialize(out_dir: DEFAULT_DIR, chunk_size: CHUNK_SIZE, contexts_per: CONTEXTS_PER)
      @out_dir = out_dir
      @chunk_size = chunk_size
      @contexts_per = contexts_per
      @stats = Hash.new(0)
    end

    def call
      FileUtils.mkdir_p(@out_dir)

      lemmas = Lemma.where(language: "el-koine", primary_gloss: nil)
                    .order(:id)
                    .pluck(:id, :lemma)
      Rails.logger.info "[#{self.class.name}] #{lemmas.size} unglossed lemmas"

      lemmas.each_slice(@chunk_size).with_index(1) do |slice, n|
        write_chunk(slice, n)
      end

      n_chunks = (lemmas.size + @chunk_size - 1) / @chunk_size
      @stats[:chunks_written] = n_chunks
      @stats[:lemmas_chunked] = lemmas.size
      Rails.logger.info "[#{self.class.name}] wrote #{n_chunks} chunks to #{@out_dir}/"
      @stats
    end

    private

    def write_chunk(slice, n)
      payload = slice.map { |id, hw| { lemma_id: id, lemma: hw, contexts: contexts_for(id) } }
      path = File.join(@out_dir, "chunk_#{n.to_s.rjust(3, '0')}.json")
      File.write(path, JSON.pretty_generate(payload))
    end

    # Pick the first N work_units (verse rows) where this lemma appears.
    # Prefer Rahlfs LXX as the source work since that's where most of
    # these lemmas were introduced. Fall back to any work if Rahlfs
    # doesn't have it.
    def contexts_for(lemma_id)
      rahlfs_id = (@rahlfs_id ||= Work.find_by(slug: "rahlfs-lxx")&.id)
      contexts = pick_contexts(lemma_id, rahlfs_id)
      contexts = pick_contexts(lemma_id, nil) if contexts.empty?
      contexts
    end

    def pick_contexts(lemma_id, work_id)
      scope = Word.joins(work_unit: :canonical_ref)
                  .where(lemma_id: lemma_id)
      scope = scope.where(work_id: work_id) if work_id
      scope
        .order("work_units.id")
        .limit(@contexts_per)
        .pluck("canonical_refs.sbl_citation", "work_units.body")
        .uniq
        .map { |ref, text| { ref: ref, text: text.to_s.gsub(/\s+/, " ").strip } }
    end
  end
end
