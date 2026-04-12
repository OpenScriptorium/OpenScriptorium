module Importers
  # Imports Ein Mishpat / Ner Mitzvah and Mesoret HaShas margin
  # references from the Sefaria link export CSVs.
  #
  # These are the two thin margin strips on a Vilna Talmud page:
  #   - Ein Mishpat (left strip): references to Mishneh Torah, Tur,
  #     Shulchan Arukh, Sefer Mitzvot Gadol
  #   - Mesoret HaShas (right strip): cross-references to parallel
  #     Talmud passages
  #
  # Both are compiled by R' Yehoshua Boaz (16th c., Italy).
  # The data is structured as cross-reference links on Sefaria.
  # We import them as work_units with formatted citation bodies,
  # aligned to Talmud daf canonical_refs so the daf controller
  # can load them alongside the other margin commentaries.
  #
  # Source: Sefaria-Export links/*.csv (CC BY-SA)
  class VilnaRefsImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/sefaria/links")

    # Use Sefaria-style names (e.g. "Bava Batra") → our canonical_work slugs
    TRACTATE_MAP = SefariaLinksImporter::SEFARIA_TO_SLUG.select { |k, _|
      SefariaLinksImporter::TRACTATE_NAMES.include?(k)
    }.freeze

    # Hebrew abbreviations for the halakhic codes cited by Ein Mishpat
    WORK_ABBREVS = {
      "Mishneh Torah" => "רמב״ם",
      "Sefer Mitzvot Gadol" => "סמ״ג",
      "Tur" => "טור",
      "Shulchan Arukh" => "שו״ע",
    }.freeze

    # Shulchan Arukh / Tur section abbreviations
    SECTION_ABBREVS = {
      "Orach Chayim" => "או״ח",
      "Yoreh De'ah" => "יו״ד",
      "Even HaEzer" => "אה״ע",
      "Choshen Mishpat" => "חו״מ",
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
      @pd = License.find_by!(name: "Public Domain")
      @ccbysa = License.find_by(name: "CC BY-SA 3.0") || @pd
      @bavli_scheme = VersificationScheme.find_by!(code: "Bavli")
      @cw_cache = {}
      @cref_cache = {}

      # Collect all references keyed by tractate+daf+amud
      @ein_mishpat = Hash.new { |h, k| h[k] = [] }
      @mesoret = Hash.new { |h, k| h[k] = [] }

      scan_csvs
      create_work_units
    end

    private

    def scan_csvs
      Dir.glob(File.join(@dir, "links*.csv")).sort.each do |path|
        next if path.include?("links_by_book")
        process_file(path)
      end
    end

    def process_file(path)
      require "csv"
      CSV.foreach(path, headers: true) do |row|
        conn_type = row["Conection Type"].to_s.strip
        case conn_type
        when "ein mishpat / ner mitsvah", "ein mishpat"
          process_ein_mishpat(row)
        when "mesorat hashas"
          process_mesoret(row)
        end
      end
      bump(:files_processed)
    end

    def process_ein_mishpat(row)
      citation1 = row["Citation 1"].to_s.strip
      citation2 = row["Citation 2"].to_s.strip
      text1 = row["Text 1"].to_s.strip
      cat1 = row["Category 1"].to_s.strip

      # Source must be a Talmud tractate
      return unless cat1 == "Talmud"
      daf_key = parse_talmud_daf_key(citation1, text1)
      return unless daf_key

      # Format the target citation in Hebrew
      formatted = format_ein_mishpat_citation(citation2)
      return unless formatted

      @ein_mishpat[daf_key] << formatted
      bump(:ein_mishpat_parsed)
    end

    def process_mesoret(row)
      citation1 = row["Citation 1"].to_s.strip
      citation2 = row["Citation 2"].to_s.strip
      text1 = row["Text 1"].to_s.strip
      text2 = row["Text 2"].to_s.strip
      cat1 = row["Category 1"].to_s.strip
      cat2 = row["Category 2"].to_s.strip

      # Both sides must be Talmud tractates
      return unless cat1 == "Talmud" && cat2 == "Talmud"
      daf_key = parse_talmud_daf_key(citation1, text1)
      return unless daf_key

      # Format target as Hebrew Talmud reference
      formatted = format_talmud_ref(citation2, text2)
      return unless formatted

      @mesoret[daf_key] << formatted
      bump(:mesoret_parsed)
    end

    # Returns [tractate_slug, daf, amud] or nil
    def parse_talmud_daf_key(citation, text_name)
      our_slug = TRACTATE_MAP[text_name]
      return nil unless our_slug

      rest = citation.sub(/\A#{Regexp.escape(text_name)}\s*/, "")
      m = rest.match(/\A(\d+)([ab])/)
      return nil unless m

      [our_slug, m[1].to_i, m[2] == "a" ? 1 : 2]
    end

    GEMATRIA_ONES = ["", "א", "ב", "ג", "ד", "ה", "ו", "ז", "ח", "ט"].freeze
    GEMATRIA_TENS = ["", "י", "כ", "ל", "מ", "נ", "ס", "ע", "פ", "צ"].freeze
    GEMATRIA_HUNDREDS = ["", "ק", "ר", "ש", "ת"].freeze

    def to_gematria(n)
      return n.to_s if n <= 0 || n > 999
      h = GEMATRIA_HUNDREDS[[n / 100, 4].min]
      r = n % 100
      # Special cases: 15 = ט״ו, 16 = ט״ז
      if r == 15 then t, o = "ט", "ו"
      elsif r == 16 then t, o = "ט", "ז"
      else t, o = GEMATRIA_TENS[r / 10], GEMATRIA_ONES[r % 10]
      end
      letters = "#{h}#{t}#{o}"
      # Add geresh (׳) for single letter, gershayim (״) before last letter for multiple
      if letters.length == 1
        "#{letters}׳"
      else
        "#{letters[0..-2]}״#{letters[-1]}"
      end
    end

    def hebraize_nums(str)
      str.gsub(/\d+/) { |m| to_gematria(m.to_i) }
    end

    # "Mishneh Torah, Blessings 1:3" → "רמב״ם א׳:ג׳"
    # "Tur, Orach Chayim 235" → "טור או״ח רל״ה"
    # "Shulchan Arukh, Orach Chayim 235:1" → "שו״ע או״ח רל״ה:א׳"
    def format_ein_mishpat_citation(citation)
      WORK_ABBREVS.each do |eng_prefix, heb_abbrev|
        next unless citation.start_with?(eng_prefix)
        rest = citation.sub(/\A#{Regexp.escape(eng_prefix)},?\s*/, "")

        # Tur / Shulchan Arukh: keep section abbreviation + siman
        SECTION_ABBREVS.each do |sec_eng, sec_heb|
          if rest.start_with?(sec_eng)
            nums = rest.sub(/\A#{Regexp.escape(sec_eng)}\s*/, "").strip
            return "#{heb_abbrev} #{sec_heb} #{hebraize_nums(nums)}"
          end
        end

        # Mishneh Torah: strip English subsection, keep only chapter:halakhah
        nums = rest.scan(/(\d+(?::\d+)?)/).flatten.last
        return nums ? "#{heb_abbrev} #{hebraize_nums(nums)}" : heb_abbrev
      end

      # Semag: "Sefer Mitzvot Gadol, Positive Commandments 82"
      nil # skip unrecognized formats
    end

    # "Berakhot 3a:5" → '<a href="/bavli/berakhot/3a">ברכות ג.</a>'
    def format_talmud_ref(citation, text_name)
      our_slug = TRACTATE_MAP[text_name]
      return nil unless our_slug

      rest = citation.sub(/\A#{Regexp.escape(text_name)}\s*/, "")
      m = rest.match(/\A(\d+)([ab])/)
      return nil unless m

      cw = find_canonical_work(our_slug)
      return nil unless cw

      amud_char = m[2] == "a" ? "." : ":"
      daf_label = "#{m[1]}#{m[2]}"
      display = "#{cw.title} #{to_gematria(m[1].to_i)}#{amud_char}"
      %(<a href="/bavli/#{our_slug}/#{daf_label}">#{display}</a>)
    end

    def create_work_units
      em_work = ensure_work(
        slug: "ein-mishpat-bavli",
        title: "Ein Mishpat / Ner Mitzvah",
        native_title: "עין משפט / נר מצוה",
        description: "Index of references from Talmud passages to major halakhic codes " \
                     "(Mishneh Torah, Tur, Shulchan Arukh, Sefer Mitzvot Gadol). " \
                     "Compiled by R' Yehoshua Boaz (16th c., Italy).",
        license: @pd
      )

      mh_work = ensure_work(
        slug: "mesoret-hashas-bavli",
        title: "Mesoret HaShas",
        native_title: "מסורת הש״ס",
        description: "Cross-references to parallel and related passages elsewhere " \
                     "in the Talmud. Compiled by R' Yehoshua Boaz (16th c., Italy).",
        license: @pd
      )

      # Wipe previous imports for idempotency
      WorkUnit.where(work_id: em_work.id).delete_all
      WorkUnit.where(work_id: mh_work.id).delete_all

      em_ord = 0
      mh_ord = 0
      em_batch = []
      mh_batch = []
      now = Time.current

      @ein_mishpat.each do |(slug, daf, amud), citations|
        cref = find_cref(slug, daf, amud)
        next unless cref

        body = citations.uniq.join(" · ")
        em_ord += 1
        label = "#{daf}#{amud == 1 ? 'a' : 'b'}"

        em_batch << {
          work_id: em_work.id,
          canonical_ref_id: cref.id,
          ord: em_ord,
          label: label,
          body: body,
          canonical_alignment_type: "approximate",
          import_run_id: @import_run.id,
          created_at: now,
          updated_at: now,
        }

        if em_batch.size >= 2000
          WorkUnit.insert_all(em_batch)
          bump(:ein_mishpat_units, em_batch.size)
          em_batch.clear
        end
      end

      @mesoret.each do |(slug, daf, amud), citations|
        cref = find_cref(slug, daf, amud)
        next unless cref

        body = citations.uniq.join(" · ")
        mh_ord += 1
        label = "#{daf}#{amud == 1 ? 'a' : 'b'}"

        mh_batch << {
          work_id: mh_work.id,
          canonical_ref_id: cref.id,
          ord: mh_ord,
          label: label,
          body: body,
          canonical_alignment_type: "approximate",
          import_run_id: @import_run.id,
          created_at: now,
          updated_at: now,
        }

        if mh_batch.size >= 2000
          WorkUnit.insert_all(mh_batch)
          bump(:mesoret_units, mh_batch.size)
          mh_batch.clear
        end
      end

      WorkUnit.insert_all(em_batch) if em_batch.any?
      WorkUnit.insert_all(mh_batch) if mh_batch.any?
      bump(:ein_mishpat_units, em_batch.size)
      bump(:mesoret_units, mh_batch.size)

      em_work.update!(imported_at: now, last_imported_at: now)
      mh_work.update!(imported_at: now, last_imported_at: now)
    end

    def ensure_work(slug:, title:, native_title:, description:, license:)
      Work.find_or_initialize_by(slug: slug).tap do |w|
        w.assign_attributes(
          title: title,
          native_title: native_title,
          work_type: "commentary",
          language: "arc",
          traditions: ["ש-rabbinic"],
          genre: "reference",
          license: license,
          default_versification_scheme: @bavli_scheme,
          source_url: "https://www.sefaria.org/",
          has_word_data: false,
          description: description
        )
        stamp(w)
        w.save!
      end
    end

    def find_canonical_work(slug)
      @cw_cache[slug] ||= CanonicalWork.find_by(slug: slug)
    end

    def find_cref(slug, daf, amud)
      key = "#{slug}:#{daf}:#{amud}"
      unless @cref_cache.key?(key)
        cw = find_canonical_work(slug)
        @cref_cache[key] = if cw
          CanonicalRef.where(canonical_work_id: cw.id)
            .where("hierarchy[1] = ? AND hierarchy[2] = ?", daf, amud)
            .order(:ord).first
        end
      end
      @cref_cache[key]
    end
  end
end
