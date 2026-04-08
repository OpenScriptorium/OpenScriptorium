require "csv"
require "open-uri"

module Importers
  # Imports the STEPBible TVTMS (Translators Versification Traditions
  # with Methodology for Standardisation) verse mapping data, and
  # populates `versification_mappings` for the parallel reader to use
  # when displaying texts that use different versification schemes
  # alongside each other.
  #
  # Source: https://github.com/STEPBible/STEPBible-Data
  # File:   Versification/TVTMS - ... - STEPBible.org CC BY.txt
  # License: CC BY 4.0 (Tyndale House Cambridge / STEPBible.org)
  #
  # The TVTMS file is the most thorough public cross-walk of verse
  # numbering across English (KJV), Hebrew (MT), Latin (Vulgate),
  # and Greek (LXX) traditions. We download it at import time rather
  # than bundling, per STEPBible's request, and credit them in the
  # ImportRun row.
  #
  # The Expanded section's columns:
  #   SourceType, SourceRef, StandardRef, Action, NoteMarker,
  #   Reversification Note, Versification Note, Ancient Versions, Tests
  #
  # Each row says: "in tradition X, the verse numbered Y is the same
  # passage as KJV verse Z (subject to the conditional Tests column,
  # which we currently ignore for simplicity)."
  #
  # We filter for the rows that produce useful versification_mappings:
  # rows where SourceType identifies a single tradition (Greek*, Hebrew,
  # Latin) AND where SourceRef differs from StandardRef. Identity rows
  # are skipped — the parallel reader's #equivalent_in helper assumes
  # identity unless a mapping says otherwise.
  class TvtmsImporter < BaseImporter
    SOURCE_URL = "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/" \
                 "Versification/TVTMS%20-%20Translators%20Versification%20Traditions%20" \
                 "with%20Methodology%20for%20Standardisation%20for%20Eng%2BHeb%2BLat%2BGrk%2B" \
                 "Others%20-%20STEPBible.org%20CC%20BY.txt"
    DEFAULT_PATH = Rails.root.join("tmp/tvtms/TVTMS.txt")

    DATA_START_MARKER = "#DataStart(Expanded)"

    # USFM/OSIS book code → canonical_works.book_key.
    # Greek-tradition rows for divergent books look up an LXX-specific
    # canonical_work; everything else uses the regular slug.
    BOOK_CODE_TO_KEY = {
      "Gen"   => "genesis",   "Exod" => "exodus",   "Lev"  => "leviticus",
      "Num"   => "numbers",   "Deut" => "deuteronomy",
      "Josh"  => "joshua",    "Judg" => "judges",   "Ruth" => "ruth",
      "1Sam"  => "1-samuel",  "2Sam" => "2-samuel",
      "1Kgs"  => "1-kings",   "2Kgs" => "2-kings",
      "1Chr"  => "1-chronicles", "2Chr" => "2-chronicles",
      "Ezra"  => "ezra",      "Neh"  => "nehemiah", "Esth" => "esther",
      "Job"   => "job",       "Psa"  => "psalms",   "Prov" => "proverbs",
      "Eccl"  => "ecclesiastes", "Song" => "song-of-solomon",
      "Isa"   => "isaiah",    "Jer"  => "jeremiah", "Lam"  => "lamentations",
      "Ezek"  => "ezekiel",   "Dan"  => "daniel",
      "Hos"   => "hosea",     "Joel" => "joel",     "Amos" => "amos",
      "Obad"  => "obadiah",   "Jonah" => "jonah",   "Mic"  => "micah",
      "Nah"   => "nahum",     "Hab"  => "habakkuk", "Zeph" => "zephaniah",
      "Hag"   => "haggai",    "Zech" => "zechariah", "Mal" => "malachi",
      "Matt"  => "matthew",   "Mark" => "mark",     "Luke" => "luke",
      "John"  => "john",      "Acts" => "acts",     "Rom"  => "romans",
      "1Cor"  => "1-corinthians", "2Cor" => "2-corinthians",
      "Gal"   => "galatians", "Eph"  => "ephesians", "Phil" => "philippians",
      "Col"   => "colossians",
      "1Thess" => "1-thessalonians", "2Thess" => "2-thessalonians",
      "1Tim"  => "1-timothy", "2Tim" => "2-timothy",
      "Titus" => "titus",     "Phlm" => "philemon",
      "Heb"   => "hebrews",   "Jas"  => "james",
      "1Pet"  => "1-peter",   "2Pet" => "2-peter",
      "1John" => "1-john",    "2John" => "2-john",  "3John" => "3-john",
      "Jude"  => "jude",      "Rev"  => "revelation",

      # Apocrypha / deuterocanon
      "Tob"    => "tobit",      "Jdt"  => "judith",
      "AddEsth" => "esther-greek",
      "EsthGr" => "esther-greek",
      "Wis"    => "wisdom",     "Sir"  => "sirach",   "Bar"  => "baruch",
      "EpJer"  => "letter-of-jeremiah",
      "PrAzar" => "prayer-of-azariah",
      "Sus"    => "susanna",    "Bel"  => "bel-and-the-dragon",
      "1Macc"  => "1-maccabees", "2Macc" => "2-maccabees",
      "3Macc"  => "3-maccabees", "4Macc" => "4-maccabees",
      "1Esd"   => "1-esdras",   "2Esd" => "2-esdras",
      "PrMan"  => "prayer-of-manasseh",
      "AddPs"  => "psalm-151",  "Ps151" => "psalm-151",
      "PssSol" => "psalms-of-solomon",
      "Odes"   => "odes"
    }.freeze

    # Books where the LXX uses a different canonical_work because of
    # versification divergence from MT/KJV.
    LXX_DIVERGENT_BOOKS = {
      "psalms"   => "psalms-lxx",
      "jeremiah" => "jeremiah-lxx",
      "job"      => "job-lxx"
    }.freeze

    # Action strings → versification_mappings.mapping_type.
    # TVTMS appends '*' to action names when the rule is conditional;
    # we strip the asterisk and treat them the same. Action names are
    # documented in the TVTMS spec at the top of the file.
    ACTION_TO_TYPE = {
      "Keep verse"          => "exact",
      "Renumber verse"      => "exact",
      "Renumber title"      => "exact",
      "Title to next verse" => "exact",
      "CopiedFrom verse"    => "exact",
      "MovedFrom verse"     => "exact",
      "IfEmpty verse"       => "exact",
      "Concatenation"       => "merge",
      "MergedNext verse"    => "merge",
      "MergedPrev verse"    => "merge",
      "DividedPrev verse"   => "split",
      "Empty verse"         => "missing",
      "Empty - merged"      => "missing"
    }.freeze

    # Reference formats we accept (with optional sub-verse marker `!a`).
    # Examples: "Gen.6:1", "Gen.6.1", "Gen.6:1!a", "Psa.9:21"
    REF_REGEX = /\A(?<book>[A-Za-z0-9]+)\.(?<ch>\d+)[:.](?<v>\d+)(?:!(?<part>[a-z]))?\z/

    def initialize(path: nil, download: nil, **opts)
      super(**opts)
      @path = path || DEFAULT_PATH
      @download = download.nil? ? !File.exist?(@path) : download
    end

    protected

    def source_url
      SOURCE_URL
    end

    def source_format
      "tsv"
    end

    def transactional?
      false
    end

    def perform
      ensure_source_present!

      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")
      @lxx_scheme = VersificationScheme.find_by!(code: "LXX")
      @mt_scheme  = VersificationScheme.find_by!(code: "MT")

      # Cache canonical_works by (slug → CanonicalWork)
      @canonical_work_cache = {}

      # Wipe and re-create. Mappings are derived purely from the source
      # file, so a fresh load is the simplest idempotency story.
      VersificationMapping.delete_all

      in_data = false
      seen_header = false
      File.foreach(@path) do |line|
        line = line.chomp.gsub(/[\t ]+\z/, "")
        next if line.empty?

        if line.start_with?(DATA_START_MARKER)
          in_data = true
          next
        end
        next unless in_data

        # Skip the header row and decoration lines
        if line.start_with?("SourceType\t")
          seen_header = true
          next
        end
        next unless seen_header
        next if line.start_with?("'")
        next if line.start_with?("#")
        next if line.start_with?("$")  # section markers like $Psa.9:1-10:18

        process_row(line.split("\t", -1))
      end

      Rails.logger.info "[TvtmsImporter] done — #{report}"
    end

    private

    def ensure_source_present!
      if @download || !File.exist?(@path)
        FileUtils.mkdir_p(File.dirname(@path))
        Rails.logger.info "[TvtmsImporter] downloading TVTMS"
        URI.open(SOURCE_URL) { |io| File.binwrite(@path, io.read) }
        bump(:downloaded)
      end
    end

    def process_row(fields)
      source_type   = fields[0].to_s.strip
      source_ref    = fields[1].to_s.strip
      standard_ref  = fields[2].to_s.strip
      action        = fields[3].to_s.strip

      # We only care about rows that identify a SINGLE source tradition
      # (not the multi-tradition Eng-KJV+Hebrew+... rows, which are
      # informational notes rather than divergence mappings).
      from_scheme = case source_type
                    when /\AGreek/   then @lxx_scheme
                    when /\AHebrew/  then @mt_scheme
                    # We skip Latin, Eng-KJV*, and combined source types.
                    else nil
                    end
      return unless from_scheme

      return if source_ref.blank? || standard_ref.blank?

      # Strip TVTMS's conditional suffix '*'
      normalized_action = action.sub(/\*\z/, "")

      # Identity rows are skipped — equivalent_in defaults to identity
      # when no mapping exists.
      return if source_ref == standard_ref && normalized_action == "Keep verse"

      mapping_type = ACTION_TO_TYPE[normalized_action]
      unless mapping_type
        bump(:unknown_actions)
        return
      end

      source_parsed = parse_ref(source_ref)
      unless source_parsed
        bump(:unparseable_source_refs)
        return
      end

      target_refs = parse_target_refs(standard_ref)
      if target_refs.empty?
        bump(:unparseable_target_refs)
        return
      end

      from_ref = lookup_canonical_ref(source_parsed, from_scheme)
      unless from_ref
        bump(:missing_source_canonical_ref)
        return
      end

      target_refs.each do |t_parsed|
        to_ref = lookup_canonical_ref(t_parsed, @kjv_scheme)
        unless to_ref
          bump(:missing_target_canonical_ref)
          next
        end

        mapping = VersificationMapping.new(
          from_scheme:        from_scheme,
          from_canonical_ref: from_ref,
          to_scheme:          @kjv_scheme,
          to_canonical_ref:   to_ref,
          mapping_type:       mapping_type,
          notes:              "TVTMS / STEPBible.org (Tyndale House Cambridge), CC BY 4.0. Source: #{source_type}, action: #{action}"
        )
        mapping.save!
        bump(:mappings_created)
      end
    end

    # Parse a single ref like "Gen.6:1" or "Gen.6:1!a".
    # Returns a Hash {book:, chapter:, verse:, part:} or nil.
    def parse_ref(ref)
      m = REF_REGEX.match(ref)
      return nil unless m
      part = m[:part] ? (m[:part].ord - 'a'.ord + 1) : nil
      {
        book:    m[:book],
        chapter: m[:ch].to_i,
        verse:   m[:v].to_i,
        part:    part
      }
    end

    # Parse a StandardRef which can be:
    #   single:        "Gen.5:31"
    #   list:          "Gen.5:32; 6:1"  (semicolon-separated; later refs may
    #                                    omit the book if same as previous)
    #   range:         "Gen.5:32-6:1"   (dash; we expand simple cases)
    #
    # Returns Array of parsed-ref hashes. Multi-book ranges and complex
    # cases get only their first endpoint.
    def parse_target_refs(text)
      results = []
      previous_book = nil

      # Semicolons separate independent refs. Within each, dashes can
      # introduce ranges that we mostly leave as the start endpoint.
      text.split(";").each do |chunk|
        chunk = chunk.strip
        next if chunk.empty?

        # Range: take the first endpoint only for v1
        chunk = chunk.split("-").first.to_s.strip if chunk.include?("-")

        # If chunk has no book prefix, inherit the previous book.
        if chunk =~ /\A(\d+)[:.](\d+)(?:!([a-z]))?\z/
          ch = $1.to_i
          v  = $2.to_i
          part = $3 ? ($3.ord - 'a'.ord + 1) : nil
          next unless previous_book
          results << { book: previous_book, chapter: ch, verse: v, part: part }
        elsif (parsed = parse_ref(chunk))
          previous_book = parsed[:book]
          results << parsed
        else
          bump(:unparseable_target_chunks)
        end
      end

      results
    end

    # Look up the canonical_ref for a parsed ref in the given scheme.
    # For LXX scheme + a divergent book, use the LXX-specific
    # canonical_work; otherwise use the book_key match.
    def lookup_canonical_ref(parsed, scheme)
      base_key = BOOK_CODE_TO_KEY[parsed[:book]]
      return nil unless base_key

      slug =
        if scheme == @lxx_scheme && LXX_DIVERGENT_BOOKS.key?(base_key)
          LXX_DIVERGENT_BOOKS[base_key]
        else
          base_key
        end

      cw = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return nil unless cw

      hierarchy = parsed[:part] ?
        [parsed[:chapter], parsed[:verse], parsed[:part]] :
        [parsed[:chapter], parsed[:verse]]

      CanonicalRef.where(canonical_work_id: cw.id, hierarchy: hierarchy).first
    end
  end
end
