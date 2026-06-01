require "json"

module Importers
  # Applies the editorial Lemma.primary_gloss seed at
  # db/seeds/lemma_glosses.json. The seed is keyed by stable
  # (language, lemma, homonym_n) so it survives id reshuffles
  # across reimports.
  #
  # Runs in the lemma-cleanup phase of import:all, AFTER the other
  # lexicon/dictionary passes — so it only fills in for lemmas the
  # automated sources couldn't gloss. By default it doesn't overwrite
  # an existing primary_gloss (the automated source is authoritative
  # where it exists). Set OVERRIDE=true to force-overwrite.
  class LemmaGlossesImporter < BaseImporter
    SEED_PATH = Rails.root.join("db/seeds/lemma_glosses.json").freeze

    def source_url    = "internal://lemma-glosses-seed"
    def source_format = "json"
    def transactional? = false

    def initialize(path: SEED_PATH, override: ENV["OVERRIDE"] == "true", **opts)
      super(**opts)
      @path = path
      @override = override
    end

    def perform
      unless File.exist?(@path)
        Rails.logger.warn "[#{self.class.name}] seed missing at #{@path}; nothing to do"
        return
      end

      entries = JSON.parse(File.read(@path))
      Rails.logger.info "[#{self.class.name}] applying #{entries.size} gloss entries"

      entries.each_slice(500) do |slice|
        ActiveRecord::Base.transaction { slice.each { |e| apply_one(e) } }
      end
    end

    private

    def apply_one(entry)
      language  = entry["language"]
      headword  = entry["lemma"]
      homonym_n = entry["homonym_n"]
      gloss     = entry["gloss"].to_s.strip

      return bump(:skipped_blank_gloss) if gloss.empty?

      scope = Lemma.where(language: language, lemma: headword)
      scope = if homonym_n
                scope.where(homonym_n: homonym_n)
              else
                # No homonym specified — match the canonical (homonym_n=1
                # or unset) row only. If multiple match, take the lowest id.
                scope.where(homonym_n: [nil, 1]).order(:id)
              end

      lemma = scope.first
      return bump(:skipped_no_lemma) unless lemma

      if lemma.primary_gloss.present? && !@override
        bump(:skipped_already_glossed)
        return
      end

      lemma.primary_gloss = gloss
      if lemma.changed?
        lemma.save!
        bump(:lemmas_glossed)
      else
        bump(:lemmas_unchanged)
      end
    end
  end
end
