module Importers
  # Imports the Babylonian Talmud (Bavli) from Sefaria's export:
  #
  #   - Gemara text (Wikisource Talmud Bavli, CC-BY-SA)
  #   - Rashi commentary (Vilna Edition, Public Domain)
  #   - Tosafot commentary (Vilna Edition, Public Domain)
  #
  # Creates:
  #   - 37 canonical_works (one per tractate)
  #   - canonical_refs at [daf, amud, segment] granularity
  #   - 3 Work records: bavli, rashi-bavli, tosafot-bavli
  #   - work_units for each segment/comment
  #
  # Addressing: hierarchy = [daf, amud, segment]
  #   daf = folio number (2-176 depending on tractate)
  #   amud = 1 (a/recto) or 2 (b/verso)
  #   segment = 1-based within the amud
  #
  # Sefaria index mapping: index 0 = daf 2a (most tractates start at 2a)
  #   daf = (index / 2) + START_DAF
  #   amud = (index % 2 == 0) ? 1 : 2
  #
  # Mishnah segments are flagged in work_units.markup as {"mishnah": true}
  # detected by the מתני׳ / מתניתין prefix in the Wikisource text.
  class BavliImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/sefaria")

    # Tractate metadata: [sefaria_slug, our_slug, hebrew_title, sbl_abbr, seder, start_daf]
    # start_daf is 2 for all standard tractates (Talmud begins on daf 2a)
    TRACTATES = [
      # Seder Zeraim
      ["berakhot",      "berakhot",      "ברכות",         "Ber.",     "zeraim",    2],
      # Seder Moed
      ["shabbat",       "shabbat",       "שבת",          "Shab.",    "moed",      2],
      ["eruvin",        "eruvin",        "עירובין",        "Eruv.",    "moed",      2],
      ["pesachim",      "pesachim",      "פסחים",         "Pes.",     "moed",      2],
      ["rosh_hashanah", "rosh-hashanah", "ראש השנה",      "Rosh Hash.", "moed",    2],
      ["yoma",          "yoma",          "יומא",          "Yoma",     "moed",      2],
      ["sukkah",        "sukkah",        "סוכה",          "Suk.",     "moed",      2],
      ["beitzah",       "beitzah",       "ביצה",          "Betz.",    "moed",      2],
      ["taanit",        "taanit",        "תענית",         "Taan.",    "moed",      2],
      ["megillah",      "megillah",      "מגילה",         "Meg.",     "moed",      2],
      ["moed_katan",    "moed-katan",    "מועד קטן",      "Moed Kat.", "moed",     2],
      ["chagigah",      "chagigah",      "חגיגה",         "Chag.",    "moed",      2],
      # Seder Nashim
      ["yevamot",       "yevamot",       "יבמות",         "Yev.",     "nashim",    2],
      ["ketubot",       "ketubot",       "כתובות",        "Ket.",     "nashim",    2],
      ["nedarim",       "nedarim",       "נדרים",         "Ned.",     "nashim",    2],
      ["nazir",         "nazir",         "נזיר",          "Naz.",     "nashim",    2],
      ["sotah",         "sotah",         "סוטה",          "Sot.",     "nashim",    2],
      ["gittin",        "gittin",        "גיטין",         "Git.",     "nashim",    2],
      ["kiddushin",     "kiddushin",     "קידושין",       "Kidd.",    "nashim",    2],
      # Seder Nezikin
      ["bava_kamma",    "bava-kamma",    "בבא קמא",      "B. Kam.",  "nezikin",   2],
      ["bava_metzia",   "bava-metzia",   "בבא מציעא",     "B. Metz.", "nezikin",   2],
      ["bava_batra",    "bava-batra",    "בבא בתרא",      "B. Bat.",  "nezikin",   2],
      ["sanhedrin",     "sanhedrin",     "סנהדרין",       "Sanh.",    "nezikin",   2],
      ["makkot",        "makkot",        "מכות",          "Mak.",     "nezikin",   2],
      ["shevuot",       "shevuot",       "שבועות",        "Shev.",    "nezikin",   2],
      ["avodah_zarah",  "avodah-zarah",  "עבודה זרה",     "Av. Zar.", "nezikin",   2],
      ["horayot",       "horayot",       "הוריות",        "Hor.",     "nezikin",   2],
      # Seder Kodashim
      ["zevachim",      "zevachim",      "זבחים",         "Zev.",     "kodashim",  2],
      ["menachot",      "menachot",      "מנחות",         "Men.",     "kodashim",  2],
      ["chullin",       "chullin",       "חולין",         "Chul.",    "kodashim",  2],
      ["bekhorot",      "bekhorot",      "בכורות",        "Bekh.",    "kodashim",  2],
      ["arakhin",       "arakhin",       "ערכין",         "Arakh.",   "kodashim",  2],
      ["temurah",       "temurah",       "תמורה",         "Tem.",     "kodashim",  2],
      ["keritot",       "keritot",       "כריתות",        "Ker.",     "kodashim",  2],
      ["meilah",        "meilah",        "מעילה",         "Meil.",    "kodashim",  2],
      ["tamid",         "tamid",         "תמיד",          "Tam.",     "kodashim", 25],
      # Seder Tahorot
      ["niddah",        "niddah",        "נידה",          "Nidd.",    "tahorot",   2],
    ].freeze

    SEDER_TITLES = {
      "zeraim"   => "זרעים",
      "moed"     => "מועד",
      "nashim"   => "נשים",
      "nezikin"  => "נזיקין",
      "kodashim" => "קדשים",
      "tahorot"  => "טהרות",
    }.freeze

    MISHNAH_RE = /\A\s*(?:מתני׳|מתניתין|<[^>]*>מתני|משנה)/

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://www.sefaria.org/"
    end

    def source_format
      "json"
    end

    def transactional?
      false
    end

    def perform
      @ccbysa = License.find_or_create_by!(name: "CC BY-SA 3.0") do |l|
        l.spdx_id = "CC-BY-SA-3.0"
        l.url = "https://creativecommons.org/licenses/by-sa/3.0/"
        l.attribution_required = true
        l.attribution_template = "Wikisource Talmud Bavli, CC BY-SA 3.0"
      end
      @pd = License.find_by!(name: "Public Domain")

      @bavli_scheme = ensure_versification_scheme
      @gemara_work  = ensure_work("bavli", "Babylonian Talmud (Gemara)",
                                  "תלמוד בבלי", @ccbysa, "commentary")
      @rashi_work   = ensure_work("rashi-bavli", "Rashi on Talmud Bavli",
                                  "רש״י על התלמוד", @pd, "commentary")
      @tosafot_work = ensure_work("tosafot-bavli", "Tosafot on Talmud Bavli",
                                  "תוספות על התלמוד", @pd, "commentary")

      TRACTATES.each do |sefaria_slug, slug, he_title, sbl_abbr, seder, start_daf|
        import_tractate(sefaria_slug, slug, he_title, sbl_abbr, seder, start_daf)
      end

      [@gemara_work, @rashi_work, @tosafot_work].each do |w|
        w.update!(last_imported_at: Time.current,
                  imported_at: w.imported_at || Time.current)
      end
    end

    private

    def ensure_versification_scheme
      VersificationScheme.find_or_create_by!(code: "Bavli") do |vs|
        vs.display_name = "Babylonian Talmud (Vilna)"
        vs.description = "Folio-based addressing of the Vilna Shas edition: tractate + daf (folio) + amud (a/b) + segment"
      end
    end

    def ensure_work(slug, title, native_title, license, work_type)
      Work.find_or_initialize_by(slug: slug).tap do |w|
        w.assign_attributes(
          title: title,
          native_title: native_title,
          work_type: work_type,
          language: "arc",  # Aramaic (with Hebrew)
          traditions: ["jewish"],
          genre: "commentary",
          license: license,
          default_versification_scheme: @bavli_scheme,
          source_url: "https://www.sefaria.org/",
          has_word_data: false,
          description: case slug
                       when "bavli"
                         "The Babylonian Talmud (Gemara), the central text of Rabbinic Judaism. Wikisource edition of the Vilna Shas, CC BY-SA 3.0."
                       when "rashi-bavli"
                         "Rashi's commentary on the Babylonian Talmud. Vilna edition, public domain."
                       when "tosafot-bavli"
                         "Tosafot (medieval Franco-German glosses) on the Babylonian Talmud. Vilna edition, public domain."
                       end
        )
        stamp(w)
        w.save!
      end
    end

    def import_tractate(sefaria_slug, slug, he_title, sbl_abbr, seder, start_daf)
      canonical_work = ensure_canonical_work(slug, he_title, sbl_abbr, seder)

      # Import Gemara
      gemara_path = File.join(@dir, "gemara", "#{sefaria_slug}.json")
      if File.exist?(gemara_path)
        data = JSON.parse(File.read(gemara_path))
        import_gemara(canonical_work, data["text"], start_daf)
        bump(:tractates_gemara)
      end

      # Import Rashi
      rashi_path = File.join(@dir, "rashi", "#{sefaria_slug}.json")
      if File.exist?(rashi_path)
        data = JSON.parse(File.read(rashi_path))
        import_commentary(canonical_work, @rashi_work, data["text"], start_daf, "rashi")
        bump(:tractates_rashi)
      end

      # Import Tosafot
      tosafot_path = File.join(@dir, "tosafot", "#{sefaria_slug}.json")
      if File.exist?(tosafot_path)
        data = JSON.parse(File.read(tosafot_path))
        import_commentary(canonical_work, @tosafot_work, data["text"], start_daf, "tosafot")
        bump(:tractates_tosafot)
      end
    end

    def ensure_canonical_work(slug, he_title, sbl_abbr, seder)
      cw = CanonicalWork.find_or_initialize_by(slug: slug)
      cw.assign_attributes(
        title: he_title,
        book_key: slug,
        testament: "rabbinic",
        citation_format: "talmud",
        sbl_abbreviation: sbl_abbr,
        versification_scheme: @bavli_scheme,
        description: "Tractate #{he_title} of the Babylonian Talmud, Seder #{SEDER_TITLES[seder]}"
      )
      cw.save!
      cw
    end

    def import_gemara(canonical_work, text_array, start_daf)
      text_array.each_with_index do |amud_segments, index|
        next unless amud_segments.is_a?(Array) && amud_segments.any?

        daf = (index / 2) + start_daf
        amud = (index % 2 == 0) ? 1 : 2

        amud_segments.each_with_index do |segment_html, seg_idx|
          next if segment_html.nil? || segment_html.strip.empty?

          seg_num = seg_idx + 1
          hierarchy = [daf, amud, seg_num]

          canonical_ref = ensure_canonical_ref(canonical_work, hierarchy, daf, amud, seg_num)

          body = strip_html(segment_html)
          next if body.empty?

          work_unit = WorkUnit.find_or_initialize_by(
            work_id: @gemara_work.id, canonical_ref_id: canonical_ref.id
          )
          if work_unit.new_record?
            work_unit.assign_attributes(
              ord: next_ord(@gemara_work.id),
              label: "#{daf}#{amud == 1 ? 'a' : 'b'}:#{seg_num}",
              canonical_alignment_type: "exact"
            )
          end

          # Detect Mishnah segments
          is_mishnah = segment_html.match?(MISHNAH_RE)
          markup = work_unit.markup || {}
          markup["mishnah"] = true if is_mishnah
          work_unit.markup = markup if markup.any?

          work_unit.body = body
          stamp(work_unit)
          work_unit.save!
          bump(:gemara_segments)
        end
      end
    end

    def import_commentary(canonical_work, commentary_work, text_array, start_daf, layer)
      text_array.each_with_index do |amud_data, index|
        next unless amud_data.is_a?(Array) && amud_data.any?

        daf = (index / 2) + start_daf
        amud = (index % 2 == 0) ? 1 : 2

        amud_data.each_with_index do |comments, seg_idx|
          next unless comments.is_a?(Array) && comments.any?

          seg_num = seg_idx + 1

          # The commentary aligns to the same canonical_ref as the Gemara segment
          canonical_ref = find_canonical_ref(canonical_work, [daf, amud, seg_num])
          next unless canonical_ref

          comments.each_with_index do |comment_html, comment_idx|
            next if comment_html.nil? || comment_html.strip.empty?

            body = strip_html(comment_html)
            next if body.empty?

            # Extract dibur hamatchil (opening phrase, typically in bold)
            dibur = extract_dibur_hamatchil(comment_html)

            # Each commentary comment is its own work_unit, linked to the
            # same canonical_ref as the Gemara segment it comments on.
            # We use a composite key to make them unique.
            label = "#{daf}#{amud == 1 ? 'a' : 'b'}:#{seg_num}.#{comment_idx + 1}"

            work_unit = WorkUnit.find_or_initialize_by(
              work_id: commentary_work.id,
              canonical_ref_id: canonical_ref.id,
              label: label
            )
            if work_unit.new_record?
              work_unit.assign_attributes(
                ord: next_ord(commentary_work.id),
                canonical_alignment_type: "exact"
              )
            end

            markup = work_unit.markup || {}
            markup["dibur_hamatchil"] = dibur if dibur.present?
            work_unit.markup = markup if markup.any?

            work_unit.body = body
            stamp(work_unit)
            work_unit.save!
            bump(:"#{layer}_comments")
          end
        end
      end
    end

    def ensure_canonical_ref(canonical_work, hierarchy, daf, amud, seg_num)
      cr = CanonicalRef.find_or_initialize_by(
        canonical_work_id: canonical_work.id,
        hierarchy: hierarchy
      )
      if cr.new_record?
        cr.assign_attributes(
          ord: next_canonical_ord(canonical_work.id),
          display_label: "#{daf}#{amud == 1 ? 'a' : 'b'}:#{seg_num}",
          sbl_citation: canonical_work.format_citation(hierarchy)
        )
        stamp(cr)
        cr.save!
        bump(:canonical_refs_created)
      end
      cr
    end

    def find_canonical_ref(canonical_work, hierarchy)
      CanonicalRef.find_by(
        canonical_work_id: canonical_work.id,
        hierarchy: hierarchy
      )
    end

    def strip_html(html)
      html
        .gsub(/<[^>]+>/, "")  # strip all HTML tags
        .gsub(/&amp;/, "&")
        .gsub(/&lt;/, "<")
        .gsub(/&gt;/, ">")
        .gsub(/&nbsp;/, " ")
        .gsub(/&quot;/, '"')
        .gsub(/\s+/, " ")
        .strip
    end

    def extract_dibur_hamatchil(html)
      # The dibur hamatchil is typically the first bold phrase
      m = html.match(/<b>([^<]+)<\/b>|<strong>([^<]+)<\/strong>/)
      return nil unless m
      text = (m[1] || m[2]).strip
      text.length > 1 ? text : nil
    end

    def next_ord(work_id)
      @ord_counters ||= {}
      @ord_counters[work_id] ||= (WorkUnit.where(work_id: work_id).maximum(:ord) || 0)
      @ord_counters[work_id] += 1
    end

    def next_canonical_ord(canonical_work_id)
      @cref_counters ||= {}
      @cref_counters[canonical_work_id] ||= (CanonicalRef.where(canonical_work_id: canonical_work_id).maximum(:ord) || 0)
      @cref_counters[canonical_work_id] += 1
    end
  end
end
