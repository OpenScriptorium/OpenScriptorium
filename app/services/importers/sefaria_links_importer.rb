module Importers
  # Imports cross-references from the Sefaria link export CSVs.
  #
  # Filters to links where BOTH sides map to works we have:
  #   - Bavli tractates (37) ↔ Tanakh books (39)
  #   - Bavli tractates ↔ Bavli tractates
  #
  # Source: Sefaria-Export links/*.csv
  # License: CC BY-SA (Sefaria data license)
  #
  # Citation parsing:
  #   Talmud: "Berakhot 2a:3" → canonical_work=berakhot, hierarchy=[2,1,3]
  #           "Berakhot 2a"   → canonical_work=berakhot, hierarchy=[2,1,1] (first segment)
  #   Tanakh: "Genesis 1:1"   → canonical_work=genesis, hierarchy=[1,1]
  #           "Numbers 29:12-38" → range, use start only
  class SefariaLinksImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/sefaria/links")

    SEFARIA_TO_SLUG = {
      # Tractates
      "Berakhot" => "berakhot", "Shabbat" => "shabbat", "Eruvin" => "eruvin",
      "Pesachim" => "pesachim", "Rosh Hashanah" => "rosh-hashanah",
      "Yoma" => "yoma", "Sukkah" => "sukkah", "Beitzah" => "beitzah",
      "Taanit" => "taanit", "Megillah" => "megillah", "Moed Katan" => "moed-katan",
      "Chagigah" => "chagigah", "Yevamot" => "yevamot", "Ketubot" => "ketubot",
      "Nedarim" => "nedarim", "Nazir" => "nazir", "Sotah" => "sotah",
      "Gittin" => "gittin", "Kiddushin" => "kiddushin",
      "Bava Kamma" => "bava-kamma", "Bava Metzia" => "bava-metzia",
      "Bava Batra" => "bava-batra", "Sanhedrin" => "sanhedrin",
      "Makkot" => "makkot", "Shevuot" => "shevuot",
      "Avodah Zarah" => "avodah-zarah", "Horayot" => "horayot",
      "Zevachim" => "zevachim", "Menachot" => "menachot", "Chullin" => "chullin",
      "Bekhorot" => "bekhorot", "Arakhin" => "arakhin", "Temurah" => "temurah",
      "Keritot" => "keritot", "Meilah" => "meilah", "Tamid" => "tamid",
      "Niddah" => "niddah",
      # Tanakh
      "Genesis" => "genesis", "Exodus" => "exodus", "Leviticus" => "leviticus",
      "Numbers" => "numbers", "Deuteronomy" => "deuteronomy",
      "Joshua" => "joshua", "Judges" => "judges", "Ruth" => "ruth",
      "I Samuel" => "1-samuel", "II Samuel" => "2-samuel",
      "I Kings" => "1-kings", "II Kings" => "2-kings",
      "I Chronicles" => "1-chronicles", "II Chronicles" => "2-chronicles",
      "Ezra" => "ezra", "Nehemiah" => "nehemiah", "Esther" => "esther",
      "Job" => "job", "Psalms" => "psalms", "Proverbs" => "proverbs",
      "Ecclesiastes" => "ecclesiastes", "Song of Songs" => "song-of-solomon",
      "Isaiah" => "isaiah", "Jeremiah" => "jeremiah", "Lamentations" => "lamentations",
      "Ezekiel" => "ezekiel", "Daniel" => "daniel",
      "Hosea" => "hosea", "Joel" => "joel", "Amos" => "amos",
      "Obadiah" => "obadiah", "Jonah" => "jonah", "Micah" => "micah",
      "Nahum" => "nahum", "Habakkuk" => "habakkuk", "Zephaniah" => "zephaniah",
      "Haggai" => "haggai", "Zechariah" => "zechariah", "Malachi" => "malachi",
    }.freeze

    TRACTATE_NAMES = Set.new(%w[
      Berakhot Shabbat Eruvin Pesachim Yoma Sukkah Beitzah Taanit Megillah Chagigah
      Yevamot Ketubot Nedarim Nazir Sotah Gittin Kiddushin
      Zevachim Menachot Chullin Bekhorot Arakhin Temurah Keritot Meilah Tamid Niddah
      Sanhedrin Makkot Shevuot Horayot
    ] + ["Rosh Hashanah", "Moed Katan", "Bava Kamma", "Bava Metzia", "Bava Batra", "Avodah Zarah"])

    TANAKH_NAMES = Set.new(%w[
      Genesis Exodus Leviticus Numbers Deuteronomy Joshua Judges Ruth
      Ezra Nehemiah Esther Job Psalms Proverbs Ecclesiastes
      Lamentations Ezekiel Daniel Hosea Joel Amos Obadiah Jonah Micah
      Nahum Habakkuk Zephaniah Haggai Zechariah Malachi Isaiah Jeremiah
    ] + ["I Samuel", "II Samuel", "I Kings", "II Kings",
         "I Chronicles", "II Chronicles", "Song of Songs"])

    # Map Sefaria connection types to our relationship_type enum
    CONNECTION_TYPE_MAP = {
      "quotation" => "quotes",
      "quotation_auto" => "quotes",
      "quotation_auto_tanakh" => "quotes",
      "allusion" => "alludes_to",
      "reference" => "cites_as_authority",
      "related" => "parallels",
      "related passage" => "parallels",
      "mesorat hashas" => "parallels",
      "ein mishpat" => "cites_as_authority",
      "ein mishpat / ner mitsvah" => "cites_as_authority",
      "" => "parallels",
    }.freeze

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://www.sefaria.org/"
    end

    def source_format
      "csv"
    end

    def transactional?
      false
    end

    def perform
      @cw_cache = {}
      @cref_cache = {}

      # Wipe previous sefaria links for idempotency
      CrossReference.where(source_dataset: "sefaria").delete_all

      batch = []
      Dir.glob(File.join(@dir, "links*.csv")).sort.each do |path|
        next if path.include?("links_by_book")
        process_file(path, batch)
      end
      flush_batch(batch)
    end

    private

    def process_file(path, batch)
      require "csv"
      CSV.foreach(path, headers: true) do |row|
        text1 = row["Text 1"].to_s.strip
        text2 = row["Text 2"].to_s.strip

        # Filter: both sides must be tractates or tanakh books we have
        t1_is_tract = TRACTATE_NAMES.include?(text1)
        t1_is_tanakh = TANAKH_NAMES.include?(text1)
        t2_is_tract = TRACTATE_NAMES.include?(text2)
        t2_is_tanakh = TANAKH_NAMES.include?(text2)

        next unless (t1_is_tract || t1_is_tanakh) && (t2_is_tract || t2_is_tanakh)

        citation1 = row["Citation 1"].to_s.strip
        citation2 = row["Citation 2"].to_s.strip
        conn_type = row["Conection Type"].to_s.strip

        source = parse_citation(citation1, text1, t1_is_tract)
        target = parse_citation(citation2, text2, t2_is_tract)
        next unless source && target

        rel_type = CONNECTION_TYPE_MAP[conn_type] || "parallels"

        batch << {
          source_canonical_work_id: source[:cw_id],
          source_range: source[:range],
          target_canonical_work_id: target[:cw_id],
          target_range: target[:range],
          relationship_type: rel_type,
          confidence: 0.8,
          source_dataset: "sefaria",
          status: "approved",
          import_run_id: @import_run.id,
          created_at: Time.current,
          updated_at: Time.current,
        }
        bump(:links_parsed)

        flush_batch(batch) if batch.size >= 5000
      end
      bump(:files_processed)
    end

    def flush_batch(batch)
      return if batch.empty?
      CrossReference.insert_all(batch)
      bump(:links_inserted, batch.size)
      batch.clear
    end

    # Parse a Sefaria citation into {cw_id:, range:}
    #
    # Talmud: "Berakhot 2a:3" or "Berakhot 2a" or "Berakhot 10a:5-7"
    # Tanakh: "Genesis 1:1" or "Numbers 29:12-38" or "Numbers 29:12"
    def parse_citation(citation, text_name, is_tractate)
      slug = SEFARIA_TO_SLUG[text_name]
      return nil unless slug

      cw = find_canonical_work(slug)
      return nil unless cw

      if is_tractate
        parse_talmud_ref(citation, text_name, cw)
      else
        parse_tanakh_ref(citation, text_name, cw)
      end
    end

    # "Berakhot 2a:3" → hierarchy [2, 1, 3]
    # "Berakhot 2a"   → hierarchy [2, 1, 1] (first segment of the amud)
    # "Berakhot 10a:5-7" → use start (10a:5)
    def parse_talmud_ref(citation, text_name, cw)
      # Strip tractate name prefix
      rest = citation.sub(/\A#{Regexp.escape(text_name)}\s*/, "")

      # Match daf + optional segment
      m = rest.match(/\A(\d+)([ab])(?::(\d+))?/)
      return nil unless m

      daf = m[1].to_i
      amud = m[2] == "a" ? 1 : 2
      seg = m[3] ? m[3].to_i : 1

      cref = find_canonical_ref(cw, [daf, amud, seg])
      return nil unless cref

      { cw_id: cw.id, range: (cref.ord...cref.ord + 1) }
    end

    # "Genesis 1:1" → hierarchy [1, 1]
    # "Numbers 29:12-38" → use start [29, 12]
    def parse_tanakh_ref(citation, text_name, cw)
      rest = citation.sub(/\A#{Regexp.escape(text_name)}\s*/, "")

      # Match chapter:verse (ignore range end)
      m = rest.match(/\A(\d+):(\d+)/)
      return nil unless m

      chapter = m[1].to_i
      verse = m[2].to_i

      cref = find_canonical_ref(cw, [chapter, verse])
      return nil unless cref

      { cw_id: cw.id, range: (cref.ord...cref.ord + 1) }
    end

    def find_canonical_work(slug)
      @cw_cache[slug] = CanonicalWork.find_by(slug: slug) unless @cw_cache.key?(slug)
      @cw_cache[slug]
    end

    def find_canonical_ref(cw, hierarchy)
      key = "#{cw.id}:#{hierarchy.join(',')}"
      unless @cref_cache.key?(key)
        @cref_cache[key] = CanonicalRef.where(
          canonical_work_id: cw.id, hierarchy: hierarchy
        ).first
      end
      @cref_cache[key]
    end
  end
end
