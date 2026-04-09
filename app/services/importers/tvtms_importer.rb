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
    CONDENSED_START_MARKER = "#DataStart(Condensed)"
    OVERLAY_PATH = Rails.root.join("db/data/tvtms_openscriptorium_overlay.tsv")

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
      "1Jn"   => "1-john",    "2Jn"   => "2-john",  "3Jn"   => "3-john",
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

    # Condensed-section book codes are 3-letter OSIS-ish (Jol, Jon, Ecc,
    # 1Sa, Ezk, Mrk, Jhn, Php...) rather than the Expanded section's
    # USFM-ish codes (Joel, Jonah, Eccl, 1Sam, Ezek, Mark, John, Phil).
    # Map everything the Condensed section uses for OT books we care about
    # back to the Expanded codes so lookup_canonical_ref resolves.
    CONDENSED_BOOK_ALIAS = {
      "Gen" => "Gen", "Exo" => "Exod", "Lev" => "Lev", "Num" => "Num",
      "Deu" => "Deut", "Jos" => "Josh", "Jdg" => "Judg",
      "1Sa" => "1Sam", "2Sa" => "2Sam",
      "1Ki" => "1Kgs", "2Ki" => "2Kgs",
      "1Ch" => "1Chr", "2Ch" => "2Chr",
      "Neh" => "Neh", "Est" => "Esth", "Esg" => "EsthGr",
      "Job" => "Job", "Psa" => "Psa", "Ps2" => "Psa",
      "Pro" => "Prov", "Ecc" => "Eccl", "Sng" => "Song",
      "Isa" => "Isa", "Jer" => "Jer", "Ezk" => "Ezek",
      "Dan" => "Dan", "Hos" => "Hos", "Jol" => "Joel", "Amo" => "Amos",
      "Jon" => "Jonah", "Mic" => "Mic", "Nam" => "Nah",
      "Hag" => "Hag", "Zec" => "Zech", "Mal" => "Mal",
      "Mat" => "Matt", "Mrk" => "Mark", "Jhn" => "John", "Act" => "Acts",
      "Rom" => "Rom", "1Co" => "1Cor", "2Co" => "2Cor", "Php" => "Phil",
      "Rev" => "Rev",
      "Tob" => "Tob", "Jdt" => "Jdt", "Wis" => "Wis", "Sir" => "Sir",
      "Bar" => "Bar", "Sus" => "Sus", "Bel" => "Bel", "Man" => "PrMan",
      "S3Y" => "PrAzar",
      "1Es" => "1Esd", "1Ma" => "1Macc", "2Ma" => "2Macc", "4Ma" => "4Macc"
    }.freeze

    # Books where the LXX uses a different canonical_work because of
    # versification divergence from MT/KJV.
    LXX_DIVERGENT_BOOKS = {
      "psalms"   => "psalms-lxx",
      "jeremiah" => "jeremiah-lxx",
      "job"      => "job-lxx"
    }.freeze

    # Books where the German tradition (Luther 1912 et al.) uses its
    # own canonical_work because Luther's verse boundaries differ from
    # both KJV and MT. The Luther1912Importer creates and populates
    # these canonical_works from Luther's TEI structure; this map tells
    # us where to look up canonical_refs for German-scheme TVTMS rows.
    GERMAN_DIVERGENT_BOOKS = {
      "psalms"     => "psalms-german",
      "3-john"     => "3-john-german",
      "revelation" => "revelation-german"
    }.freeze

    # Books where the MT uses a different canonical_work because of
    # versification divergence from KJV. Every MT-scheme TVTMS row for
    # these books is routed to the `*-mt` canonical_work so the
    # resulting versification_mapping's from_canonical_ref actually
    # differs from its to_canonical_ref (otherwise
    # CanonicalRef#equivalent_in short-circuits via the same-scheme
    # identity rule and the mapping never fires).
    MT_DIVERGENT_BOOKS = {
      "genesis"      => "genesis-mt",
      "leviticus"    => "leviticus-mt",
      "numbers"      => "numbers-mt",
      "1-samuel"     => "1-samuel-mt",
      "2-samuel"     => "2-samuel-mt",
      "1-kings"      => "1-kings-mt",
      "2-kings"      => "2-kings-mt",
      "nehemiah"     => "nehemiah-mt",
      "job"          => "job-mt",
      "psalms"       => "psalms-mt",
      "ecclesiastes" => "ecclesiastes-mt",
      "isaiah"       => "isaiah-mt",
      "jeremiah"     => "jeremiah-mt",
      "ezekiel"      => "ezekiel-mt",
      "daniel"       => "daniel-mt",
      "hosea"        => "hosea-mt",
      "joel"         => "joel-mt",
      "jonah"        => "jonah-mt",
      "micah"        => "micah-mt",
      "malachi"      => "malachi-mt"
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

      @kjv_scheme    = VersificationScheme.find_by!(code: "KJV")
      @lxx_scheme    = VersificationScheme.find_by!(code: "LXX")
      @mt_scheme     = VersificationScheme.find_by!(code: "MT")
      @german_scheme = VersificationScheme.find_by!(code: "German")

      # Cache canonical_works by (slug → CanonicalWork)
      @canonical_work_cache = {}

      # Wipe and re-create. Mappings are derived purely from the source
      # file, so a fresh load is the simplest idempotency story.
      VersificationMapping.delete_all

      # First pass: the Condensed section is KJV-centric but columns are
      # fixed as [English KJV, Hebrew, Latin, Greek, ...] per `$Section`
      # header. OneToOne rows give us the bulk Hebrew↔KJV chapter shifts
      # (Joel 2:28↔3:1, Jonah 1:17↔2:1, Gen 31:55↔32:1, Eccl 4:17↔5:1,
      # 1Sam 23:29↔24:1, Num 16:36↔17:1, etc.) that the Expanded section
      # only emits as Eng-KJV "Keep verse" rows. The Expanded pass below
      # still runs and remains the authoritative source for psalm title
      # renumbers and sub-verse splits.
      process_condensed_section!

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

      load_openscriptorium_overlay!

      expand_chapter_renumbers!

      Rails.logger.info "[TvtmsImporter] done — #{report}"
    end

    # Load db/data/tvtms_openscriptorium_overlay.tsv after the upstream
    # TVTMS data. The overlay extends the upstream German rows with
    # mappings for passages where Luther 1912's verse boundaries
    # diverge from KJV but the upstream STEPBible coverage doesn't have
    # rows. Format is identical to upstream TVTMS — same column order
    # — but the file is committed to the repo and only contains
    # `German` rows. Lines starting with `#` are comments.
    #
    # Overlay rows fail soft: if a German canonical_ref doesn't exist
    # yet (because Luther1912Importer hasn't run yet to create the
    # `*-german` canonical_works), the row is skipped and counted in
    # `:overlay_missing_source_canonical_ref`. The user re-runs
    # `import:tvtms` after `import:luther1912` to populate the German
    # mappings.
    def load_openscriptorium_overlay!
      return unless File.exist?(OVERLAY_PATH)

      seen_header = false
      File.foreach(OVERLAY_PATH) do |line|
        line = line.chomp
        next if line.empty?
        next if line.start_with?("#")

        if line.start_with?("SourceType\t")
          seen_header = true
          next
        end
        next unless seen_header

        process_row(line.split("\t", -1))
        bump(:overlay_rows_processed)
      end
    end

    # TVTMS optimizes its file by emitting a SINGLE "Renumber verse" row
    # for psalms (and other chapters) that simply shift by a constant
    # offset across the whole chapter. For example, the only Latin+Greek
    # row for LXX Psalm 13 is `Psa.13:1 → Psa.14:1`. The implication is
    # that LXX 13:2..N also shift by +1 chapter and 0 verses; consumers
    # are expected to extrapolate.
    #
    # This pass walks every (source canonical_work, source chapter) pair
    # that has at least one explicit "exact verse renumber" mapping
    # crossing chapter boundaries, derives the (chapter_offset,
    # verse_offset) implied by those rows, and synthesizes mapping rows
    # for any source canonical_ref in the chapter that doesn't already
    # have one. A chapter is only expanded if every existing exact
    # cross-chapter renumber mapping in it agrees on the same offset
    # (otherwise the data is non-uniform and we leave it alone).
    #
    # Skipped automatically:
    #   * source verses that already have any mapping (don't overwrite
    #     splits, merges, missings, or explicit exact rows)
    #   * source verses with no corresponding target canonical_ref at
    #     the offset position (e.g. when the source chapter has more
    #     verses than the target — the extras stay unmapped)
    #   * sub-verse refs (hierarchy length > 2) — splits are explicit
    #
    # Without this pass, lookups for inner verses of simply-shifted
    # psalms fall through to the identity-fallback in
    # CanonicalRef#equivalent_in and silently produce wrong results.
    def expand_chapter_renumbers!
      mappings_by_chapter = VersificationMapping
                              .includes(:from_canonical_ref, :to_canonical_ref,
                                        :from_scheme, :to_scheme)
                              .to_a
                              .group_by do |m|
                                fcr = m.from_canonical_ref
                                [fcr.canonical_work_id, fcr.hierarchy[0]]
                              end

      mappings_by_chapter.each do |(source_cw_id, source_ch), mappings|
        # Only consider exact whole-verse cross-chapter renumber rows.
        renumbers = mappings.select do |m|
          fcr = m.from_canonical_ref
          tcr = m.to_canonical_ref
          m.mapping_type == "exact" &&
            fcr.hierarchy.length == 2 &&
            tcr.hierarchy.length == 2 &&
            fcr.hierarchy[0] != tcr.hierarchy[0]
        end
        next if renumbers.empty?

        # Derive offsets from the first such row.
        first        = renumbers.first
        chap_offset  = first.to_canonical_ref.hierarchy[0] - first.from_canonical_ref.hierarchy[0]
        verse_offset = first.to_canonical_ref.hierarchy[1] - first.from_canonical_ref.hierarchy[1]

        # Bail if any other renumber row in the chapter disagrees.
        consistent = renumbers.all? do |m|
          (m.to_canonical_ref.hierarchy[0] - m.from_canonical_ref.hierarchy[0]) == chap_offset &&
            (m.to_canonical_ref.hierarchy[1] - m.from_canonical_ref.hierarchy[1]) == verse_offset
        end
        unless consistent
          bump(:chapter_shift_inconsistent)
          next
        end

        target_cw_id = first.to_canonical_ref.canonical_work_id
        target_ch    = source_ch + chap_offset

        # Verses already covered by ANY mapping (don't clobber splits/
        # merges/missings or existing exact rows).
        covered_verses = mappings.map { |m|
          h = m.from_canonical_ref.hierarchy
          h.length == 2 ? h[1] : nil
        }.compact.to_set

        # Walk every whole-verse source ref in this chapter and fill in
        # the gaps.
        CanonicalRef
          .where(canonical_work_id: source_cw_id)
          .where("hierarchy[1] = ?", source_ch)
          .where("array_length(hierarchy, 1) = 2")
          .order(:ord)
          .each do |sr|
            sv = sr.hierarchy[1]
            next if covered_verses.include?(sv)

            tv = sv + verse_offset
            next if tv < 1

            target_ref = CanonicalRef
                           .where(canonical_work_id: target_cw_id, hierarchy: [target_ch, tv])
                           .first
            unless target_ref
              bump(:chapter_shift_no_target)
              next
            end

            VersificationMapping.create!(
              from_scheme:        first.from_scheme,
              from_canonical_ref: sr,
              to_scheme:          first.to_scheme,
              to_canonical_ref:   target_ref,
              mapping_type:       "exact",
              notes:              "Synthesized: chapter-shift expansion " \
                                  "(ch#{format('%+d', chap_offset)}, " \
                                  "v#{format('%+d', verse_offset)})"
            )
            bump(:chapter_shift_synthesized)
          end
      end
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

    # Parse the TVTMS Condensed section. Columns are, in every
    # `$Section ...` header, `English KJV | Hebrew | Latin | Greek |
    # (others)`. We only handle the `OneToOne` action for now: for each
    # such row, if the Hebrew ref differs from the English KJV ref,
    # create a Hebrew → KJV mapping (expanding range forms verse-by-verse).
    def process_condensed_section!
      in_section = false
      File.foreach(@path) do |line|
        line = line.chomp
        if line.start_with?(CONDENSED_START_MARKER)
          in_section = true
          next
        end
        if line.start_with?(DATA_START_MARKER)
          in_section = false
          break
        end
        next unless in_section

        fields = line.split("\t", -1)
        action = fields[0].to_s.strip
        next unless action == "OneToOne"

        eng_raw = fields[1].to_s.strip
        heb_raw = fields[2].to_s.strip
        next if eng_raw.empty? || heb_raw.empty?
        next if heb_raw.start_with?("Absent")
        next if eng_raw == heb_raw

        eng_refs = expand_condensed_ref(eng_raw)
        heb_refs = expand_condensed_ref(heb_raw)
        next if eng_refs.empty? || heb_refs.empty?
        next unless eng_refs.length == heb_refs.length

        heb_refs.zip(eng_refs).each do |heb, eng|
          next if heb == eng

          from_ref = lookup_canonical_ref(heb, @mt_scheme)
          unless from_ref
            bump(:condensed_missing_mt_ref)
            next
          end
          to_ref = lookup_canonical_ref(eng, @kjv_scheme)
          unless to_ref
            bump(:condensed_missing_kjv_ref)
            next
          end

          VersificationMapping.create!(
            from_scheme:        @mt_scheme,
            from_canonical_ref: from_ref,
            to_scheme:          @kjv_scheme,
            to_canonical_ref:   to_ref,
            mapping_type:       "exact",
            notes:              "TVTMS / STEPBible.org Condensed OneToOne (Hebrew↔English KJV), CC BY 4.0"
          )
          bump(:condensed_mappings_created)
        end
      end
    end

    # Expand a Condensed-section ref cell into a flat list of parsed
    # single-verse refs. Supports:
    #   "Gen.32:1"          → [{book:Gen, chapter:32, verse:1}]
    #   "Gen.32:1-32"       → 32 refs Gen.32:1..32
    #   "Gen.5:31.1"        → sub-verse part 1
    #   "Gen.5:31.2"        → sub-verse part 2
    # Ranges that cross chapters, ranges with sub-verse parts, and any
    # unparseable cell return [].
    def expand_condensed_ref(cell)
      cell = cell.strip
      return [] if cell.empty? || cell.start_with?("Absent")

      # Single ref (possibly with sub-verse part)
      if (m = cell.match(/\A([A-Za-z0-9]+)\.(\d+):(\d+)(?:\.(\d+))?\z/))
        book = CONDENSED_BOOK_ALIAS[m[1]] || m[1]
        return [{ book: book, chapter: m[2].to_i, verse: m[3].to_i, part: m[4]&.to_i }]
      end

      # Simple same-chapter range: "Book.C:V1-V2"
      if (m = cell.match(/\A([A-Za-z0-9]+)\.(\d+):(\d+)-(\d+)\z/))
        book = CONDENSED_BOOK_ALIAS[m[1]] || m[1]
        ch   = m[2].to_i
        v1   = m[3].to_i
        v2   = m[4].to_i
        return [] if v2 < v1
        return (v1..v2).map { |v| { book: book, chapter: ch, verse: v, part: nil } }
      end

      []
    end

    def process_row(fields)
      source_type   = fields[0].to_s.strip
      source_ref    = fields[1].to_s.strip
      standard_ref  = fields[2].to_s.strip
      action        = fields[3].to_s.strip

      # We only care about rows tagged with the specific source-tradition
      # convention used by the texts we actually host.
      #
      # TVTMS encodes several Greek conventions and uses inconsistent
      # word ordering for combined-tradition labels (`Latin+Greek` vs
      # `Greek+Latin` for the same kind of rule).
      #
      # Our Rahlfs/CCAT data follows the **title-as-v1** convention
      # (Ps 9 has 39 verses, with the title numbered as v1) — TVTMS
      # tags those rules with the bare token `Greek` (in any position
      # of a `+`-joined label). The alternative `Greek2` token marks
      # the title-merged convention (NETS / Brenton, Ps 9 = 38 verses)
      # and would produce an off-by-one error against our data.
      #
      # Matching strategy: split the source-type label on `+` and check
      # whether any part is exactly `Greek` (for LXX) or exactly
      # `Hebrew` (for MT). This catches `Greek`, `Latin+Greek`,
      # `Greek+Latin`, `Hebrew+Greek`, `Hebrew+Latin+Greek`, etc.,
      # while excluding `Greek2`, `Greek3`, `GreekIntegrated`,
      # `Eng-KJV+...`, and other variants. A combined `Hebrew+Greek`
      # row produces mappings in *both* schemes because the rule
      # applies to both traditions simultaneously.
      tokens = source_type.split("+").map(&:strip)
      from_schemes = []
      from_schemes << @lxx_scheme    if tokens.include?("Greek")
      from_schemes << @mt_scheme     if tokens.include?("Hebrew")
      from_schemes << @german_scheme if tokens.include?("German")
      return if from_schemes.empty?

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

      from_schemes.each do |from_scheme|
        from_ref = lookup_canonical_ref(source_parsed, from_scheme)
        unless from_ref
          bump(:missing_source_canonical_ref)
          next
        end

        target_refs.each do |t_parsed|
          to_ref = lookup_canonical_ref(t_parsed, @kjv_scheme)
          unless to_ref
            bump(:missing_target_canonical_ref)
            next
          end

          # Idempotency: a single TVTMS/overlay run can encode the same
          # logical (from, to, type) twice via two slightly different
          # action rows (e.g. "Renumber verse" + "Concatenation" pair
          # for the same target). Use find_or_create to dedupe.
          attrs = {
            from_scheme_id:        from_scheme.id,
            from_canonical_ref_id: from_ref.id,
            to_scheme_id:          @kjv_scheme.id,
            to_canonical_ref_id:   to_ref.id,
            mapping_type:          mapping_type
          }
          if VersificationMapping.exists?(attrs)
            bump(:mappings_deduped)
          else
            VersificationMapping.create!(
              **attrs,
              notes: "TVTMS / STEPBible.org (Tyndale House Cambridge), CC BY 4.0. Source: #{source_type}, action: #{action}"
            )
            bump(:mappings_created)
          end
        end
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
        elsif scheme == @mt_scheme && MT_DIVERGENT_BOOKS.key?(base_key)
          MT_DIVERGENT_BOOKS[base_key]
        elsif scheme == @german_scheme && GERMAN_DIVERGENT_BOOKS.key?(base_key)
          GERMAN_DIVERGENT_BOOKS[base_key]
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
