require "open-uri"

module Importers
  # Imports the STEPBible TBESG (Translators Brief Lexicon of Extended
  # Strong's for Greek). Source license: CC BY 4.0.
  #
  # TBESG is based on Abbott-Smith's Manual Greek Lexicon and edited
  # by Tyndale House. It covers NT vocabulary (~5,500 entries) plus
  # LXX-specific words and variant readings via the Extended Strong's
  # range. Headwords are already polytonic Unicode — no Beta Code
  # decoding needed.
  #
  # Use: populates Lemma.primary_gloss for el-koine lemmas that don't
  # already have one (LSJ + Hebrew cross-link run first). Optionally
  # creates a LexiconEntry row with source="TBESG" for the full
  # Abbott-Smith definition body.
  #
  # The TBESG file mixes proper-name records ($==========PERSON style)
  # with tabular lexicon rows. We only ingest the tabular rows, which
  # begin with a Strong's number (G\d+).
  class TbesgImporter < BaseImporter
    SOURCE = "TBESG".freeze
    SOURCE_URL = "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/" \
                 "Lexicons/TBESG%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs" \
                 "%20for%20Greek%20-%20STEPBible.org%20CC%20BY.txt".freeze

    def source_url    = SOURCE_URL
    def source_format = "tsv"
    def transactional? = false

    def perform
      @license_id = License.find_by(spdx_id: "CC-BY-4.0")&.id

      path = ENV["TBESG_PATH"].presence || download
      Rails.logger.info "[#{self.class.name}] parsing #{path}"

      File.foreach(path).with_index do |line, lineno|
        process_line(line)
      end
    end

    private

    def download
      target = Rails.root.join("tmp/tbesg.txt")
      FileUtils.mkdir_p(target.dirname)
      Rails.logger.info "[#{self.class.name}] downloading #{SOURCE_URL}"
      URI.open(SOURCE_URL) { |io| File.open(target, "wb") { |f| IO.copy_stream(io, f) } }
      target.to_s
    end

    def process_line(line)
      # Only rows beginning with G followed by digits are lexicon entries.
      return unless line =~ /\AG\d+\t/

      fields = line.chomp.split("\t")
      strong       = fields[0]&.strip
      raw_headword = fields[3]
      brief_gloss  = fields[6]&.strip.presence
      full_def     = fields[7]

      return if raw_headword.blank? || brief_gloss.blank?

      # Headword field can contain multiple comma-separated forms
      # ("α, Ἀλφα"). Try each in turn.
      headwords = raw_headword.split(/\s*,\s*/).map { |h| h.unicode_normalize(:nfc).strip }
                              .reject(&:empty?)

      headwords.each do |headword|
        link_lemma(headword, strong, brief_gloss, full_def)
      end
    end

    def link_lemma(headword, strong, brief_gloss, full_def)
      lemma = Lemma.find_by(language: "el-koine", lemma: headword)
      return bump(:headwords_no_lemma) unless lemma

      changed = false
      if lemma.primary_gloss.blank?
        lemma.primary_gloss = brief_gloss
        changed = true
      end

      if changed
        lemma.save!
        bump(:lemmas_glossed)
      else
        bump(:lemmas_already_glossed)
      end
    end
  end
end
