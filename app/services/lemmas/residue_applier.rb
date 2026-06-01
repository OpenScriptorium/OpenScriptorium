require "csv"

module Lemmas
  # Reads per-chunk TSV gloss files produced by an editorial review of
  # the residue chunks (Lemmas::ResidueChunker output) and writes the
  # glosses into Lemma.primary_gloss.
  #
  # Expected TSV layout per chunk file (header row, tab-separated):
  #   lemma_id\tgloss\tnotes
  #
  # `notes` is optional and ignored on import. A row whose `gloss` is
  # blank, "?", or "UNKNOWN" is skipped (reviewer wasn't confident).
  #
  # Idempotent: re-running won't trample a non-blank primary_gloss
  # already on a Lemma, unless OVERRIDE=true is set.
  class ResidueApplier < Importers::BaseImporter
    DEFAULT_DIR = "/tmp/gloss_chunks".freeze
    SKIP_VALUES = ["", "?", "??", "UNKNOWN", "unknown", "n/a", "N/A"].to_set.freeze

    def initialize(dir: DEFAULT_DIR, override: false, **opts)
      super(**opts)
      @dir = dir
      @override = override
    end

    def source_url    = "internal://editorial-residue"
    def source_format = "tsv"
    def transactional? = false

    def perform
      files = Dir.glob(File.join(@dir, "chunk_*.glosses.tsv")).sort
      if files.empty?
        Rails.logger.warn "[#{self.class.name}] no chunk_*.glosses.tsv files in #{@dir}"
        return
      end

      files.each do |path|
        ActiveRecord::Base.transaction { apply_file(path) }
      end
    end

    private

    def apply_file(path)
      Rails.logger.info "[#{self.class.name}] #{File.basename(path)}"
      File.foreach(path).with_index do |line, lineno|
        next if lineno.zero?  # header
        next if line.strip.empty?

        fields = line.chomp.split("\t")
        lemma_id = fields[0].to_i
        gloss    = fields[1].to_s.strip

        if SKIP_VALUES.include?(gloss)
          bump(:skipped_blank_or_unknown)
          next
        end

        apply_one(lemma_id, gloss)
      end
      bump(:files_applied)
    end

    def apply_one(lemma_id, gloss)
      lemma = Lemma.find_by(id: lemma_id)
      return bump(:skipped_lemma_missing) unless lemma

      if lemma.primary_gloss.present? && !@override
        bump(:skipped_already_glossed)
        return
      end

      lemma.primary_gloss = gloss
      if lemma.changed?
        stamp(lemma) if lemma.import_run_id.nil?
        lemma.save!
        bump(:lemmas_glossed)
      else
        bump(:lemmas_unchanged)
      end
    end
  end
end
