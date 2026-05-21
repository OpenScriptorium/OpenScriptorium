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

    # Tractate metadata: [sefaria_slug, our_slug, hebrew_title, sbl_abbr, seder]
    # Sefaria arrays always index from daf 1: index 0 = daf 1a, index 1 = 1b, etc.
    # Most tractates start on 2a (index 2); Tamid starts on 25b (index 49).
    # The formula is always: daf = (index / 2) + 1, amud = a if even else b.
    TRACTATES = [
      # Seder Zeraim
      ["berakhot",      "berakhot",      "ברכות",         "Ber.",     "zeraim"],
      # Seder Moed
      ["shabbat",       "shabbat",       "שבת",          "Shab.",    "moed"],
      ["eruvin",        "eruvin",        "עירובין",        "Eruv.",    "moed"],
      ["pesachim",      "pesachim",      "פסחים",         "Pes.",     "moed"],
      ["rosh_hashanah", "rosh-hashanah", "ראש השנה",      "Rosh Hash.", "moed"],
      ["yoma",          "yoma",          "יומא",          "Yoma",     "moed"],
      ["sukkah",        "sukkah",        "סוכה",          "Suk.",     "moed"],
      ["beitzah",       "beitzah",       "ביצה",          "Betz.",    "moed"],
      ["taanit",        "taanit",        "תענית",         "Taan.",    "moed"],
      ["megillah",      "megillah",      "מגילה",         "Meg.",     "moed"],
      ["moed_katan",    "moed-katan",    "מועד קטן",      "Moed Kat.", "moed"],
      ["chagigah",      "chagigah",      "חגיגה",         "Chag.",    "moed"],
      # Seder Nashim
      ["yevamot",       "yevamot",       "יבמות",         "Yev.",     "nashim"],
      ["ketubot",       "ketubot",       "כתובות",        "Ket.",     "nashim"],
      ["nedarim",       "nedarim",       "נדרים",         "Ned.",     "nashim"],
      ["nazir",         "nazir",         "נזיר",          "Naz.",     "nashim"],
      ["sotah",         "sotah",         "סוטה",          "Sot.",     "nashim"],
      ["gittin",        "gittin",        "גיטין",         "Git.",     "nashim"],
      ["kiddushin",     "kiddushin",     "קידושין",       "Kidd.",    "nashim"],
      # Seder Nezikin
      ["bava_kamma",    "bava-kamma",    "בבא קמא",      "B. Kam.",  "nezikin"],
      ["bava_metzia",   "bava-metzia",   "בבא מציעא",     "B. Metz.", "nezikin"],
      ["bava_batra",    "bava-batra",    "בבא בתרא",      "B. Bat.",  "nezikin"],
      ["sanhedrin",     "sanhedrin",     "סנהדרין",       "Sanh.",    "nezikin"],
      ["makkot",        "makkot",        "מכות",          "Mak.",     "nezikin"],
      ["shevuot",       "shevuot",       "שבועות",        "Shev.",    "nezikin"],
      ["avodah_zarah",  "avodah-zarah",  "עבודה זרה",     "Av. Zar.", "nezikin"],
      ["horayot",       "horayot",       "הוריות",        "Hor.",     "nezikin"],
      # Seder Kodashim
      ["zevachim",      "zevachim",      "זבחים",         "Zev.",     "kodashim"],
      ["menachot",      "menachot",      "מנחות",         "Men.",     "kodashim"],
      ["chullin",       "chullin",       "חולין",         "Chul.",    "kodashim"],
      ["bekhorot",      "bekhorot",      "בכורות",        "Bekh.",    "kodashim"],
      ["arakhin",       "arakhin",       "ערכין",         "Arakh.",   "kodashim"],
      ["temurah",       "temurah",       "תמורה",         "Tem.",     "kodashim"],
      ["keritot",       "keritot",       "כריתות",        "Ker.",     "kodashim"],
      ["meilah",        "meilah",        "מעילה",         "Meil.",    "kodashim"],
      ["tamid",         "tamid",         "תמיד",          "Tam.",     "kodashim"],
      # Seder Tahorot
      ["niddah",        "niddah",        "נידה",          "Nidd.",    "tahorot"],
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
      download_source

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

      TRACTATES.each do |sefaria_slug, slug, he_title, sbl_abbr, seder|
        import_tractate(sefaria_slug, slug, he_title, sbl_abbr, seder)
      end

      [@gemara_work, @rashi_work, @tosafot_work].each do |w|
        w.update!(last_imported_at: Time.current,
                  imported_at: w.imported_at || Time.current)
      end
    end

    # Fetch each tractate's Gemara, Rashi, Tosafot via Sefaria's v3 API.
    # 37 tractates × 3 layers = 111 API calls (~6 min on cold cache).
    # Skips files that already exist.
    #
    # Versions chosen for FOSS-license compatibility:
    #   Gemara: Wikisource Talmud Bavli (CC-BY-SA) — NOT William Davidson (CC-BY-NC)
    #   Rashi:  Vilna Edition (Public Domain)
    #   Tosafot: Vilna Edition (Public Domain)
    #
    # The saved JSON has the simple `{"text": [...]}` shape the importer
    # expects (2D array — outer = daf, inner = lines), reshaped from
    # v3's `versions[0].text`.
    SEFARIA_VERSIONS = {
      "gemara"  => "hebrew|Wikisource Talmud Bavli",
      "rashi"   => "hebrew|Vilna Edition",
      "tosafot" => "hebrew|Vilna Edition"
    }.freeze

    def download_source
      require "open-uri"
      require "uri"
      require "json"
      %w[gemara rashi tosafot].each { |sub| FileUtils.mkdir_p(File.join(@dir, sub)) }
      TRACTATES.each do |sefaria_slug, _, _, _, _|
        # Sefaria expects each word capitalized for multi-word tractates
        # ("Rosh_Hashanah", "Bava_Kamma"). Single-word lowercase is
        # tolerated for the top tractate URL but NOT for compound names
        # ("Rashi on berakhot" → "Could not find title"). Use title-case
        # + underscore consistently.
        title_cased = sefaria_slug.split("_").map(&:capitalize).join("_")
        fetch_sefaria_text("gemara",  sefaria_slug, title_cased)
        fetch_sefaria_text("rashi",   sefaria_slug, "Rashi on #{title_cased}")
        fetch_sefaria_text("tosafot", sefaria_slug, "Tosafot on #{title_cased}")
      end
    end

    def fetch_sefaria_text(subdir, sefaria_slug, sefaria_text_name)
      path = File.join(@dir, subdir, "#{sefaria_slug}.json")
      return if File.exist?(path) && File.size(path) > 100

      escaped_name    = URI::DEFAULT_PARSER.escape(sefaria_text_name)
      escaped_version = URI::DEFAULT_PARSER.escape(SEFARIA_VERSIONS[subdir])
      url = "https://www.sefaria.org/api/v3/texts/#{escaped_name}?version=#{escaped_version}&fill_in_missing_segments=1"
      Rails.logger.info "[BavliImporter] fetching #{subdir}/#{sefaria_slug}.json"
      begin
        body = URI.open(url, read_timeout: 60).read
        parsed = JSON.parse(body)
        version = parsed["versions"]&.first
        text = version ? version["text"] : []
        # Save in the simple format the importer reads.
        File.write(path, JSON.generate({ "text" => text }))
        bump(:source_downloaded)
      rescue OpenURI::HTTPError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError => e
        Rails.logger.warn "[BavliImporter] #{subdir}/#{sefaria_slug}: #{e.message}"
        bump(:source_download_skipped)
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
          traditions: ["ש-rabbinic"],
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

    def import_tractate(sefaria_slug, slug, he_title, sbl_abbr, seder)
      canonical_work = ensure_canonical_work(slug, he_title, sbl_abbr, seder)

      # Import Gemara
      gemara_path = File.join(@dir, "gemara", "#{sefaria_slug}.json")
      if File.exist?(gemara_path)
        data = JSON.parse(File.read(gemara_path))
        import_gemara(canonical_work, data["text"])
        bump(:tractates_gemara)
      end

      # Import Rashi
      rashi_path = File.join(@dir, "rashi", "#{sefaria_slug}.json")
      if File.exist?(rashi_path)
        data = JSON.parse(File.read(rashi_path))
        import_commentary(canonical_work, @rashi_work, data["text"], "rashi")
        bump(:tractates_rashi)
      end

      # Import Tosafot
      tosafot_path = File.join(@dir, "tosafot", "#{sefaria_slug}.json")
      if File.exist?(tosafot_path)
        data = JSON.parse(File.read(tosafot_path))
        import_commentary(canonical_work, @tosafot_work, data["text"], "tosafot")
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

    BATCH_SIZE = 2000

    def import_gemara(canonical_work, text_array)
      # Pre-load existing gemara work_units keyed by canonical_ref_id
      existing = WorkUnit.where(work_id: @gemara_work.id)
                         .pluck(:canonical_ref_id, :ord)
                         .to_h
      batch = []
      now = Time.current

      text_array.each_with_index do |amud_segments, index|
        next unless amud_segments.is_a?(Array) && amud_segments.any?

        daf = (index / 2) + 1
        amud = (index % 2 == 0) ? 1 : 2

        amud_segments.each_with_index do |segment_html, seg_idx|
          next if segment_html.nil? || segment_html.strip.empty?

          seg_num = seg_idx + 1
          hierarchy = [daf, amud, seg_num]

          canonical_ref = ensure_canonical_ref(canonical_work, hierarchy,
            label: "#{daf}#{amud == 1 ? 'a' : 'b'}:#{seg_num}")

          body = strip_html(segment_html)
          next if body.empty?

          ord = existing[canonical_ref.id] || next_ord(@gemara_work.id)
          existing[canonical_ref.id] ||= ord

          is_mishnah = segment_html.match?(MISHNAH_RE)
          markup = is_mishnah ? { "mishnah" => true } : {}

          batch << {
            work_id: @gemara_work.id,
            canonical_ref_id: canonical_ref.id,
            ord: ord,
            label: "#{daf}#{amud == 1 ? 'a' : 'b'}:#{seg_num}",
            body: body,
            canonical_alignment_type: "exact",
            markup: markup,
            import_run_id: @import_run.id,
            created_at: now,
            updated_at: now
          }

          if batch.size >= BATCH_SIZE
            WorkUnit.upsert_all(batch, unique_by: [:work_id, :ord])
            batch = []
          end
          bump(:gemara_segments)
        end
      end
      WorkUnit.upsert_all(batch, unique_by: [:work_id, :ord]) if batch.any?
    end

    def import_commentary(canonical_work, commentary_work, text_array, layer)
      # Pre-load existing commentary work_units keyed by [canonical_ref_id, label]
      existing = {}
      WorkUnit.where(work_id: commentary_work.id).pluck(:canonical_ref_id, :label, :ord).each do |cref_id, label, ord|
        existing[[cref_id, label]] = ord
      end
      batch = []
      now = Time.current

      text_array.each_with_index do |amud_data, index|
        next unless amud_data.is_a?(Array) && amud_data.any?

        daf = (index / 2) + 1
        amud = (index % 2 == 0) ? 1 : 2

        amud_data.each_with_index do |comments, seg_idx|
          next unless comments.is_a?(Array) && comments.any?

          seg_num = seg_idx + 1

          canonical_ref = find_canonical_ref(canonical_work, [daf, amud, seg_num])
          next unless canonical_ref

          comments.each_with_index do |comment_html, comment_idx|
            next if comment_html.nil? || comment_html.strip.empty?

            body = strip_html(comment_html)
            next if body.empty?

            dibur = extract_dibur_hamatchil(comment_html)
            label = "#{daf}#{amud == 1 ? 'a' : 'b'}:#{seg_num}.#{comment_idx + 1}"

            ord = existing[[canonical_ref.id, label]] || next_ord(commentary_work.id)
            existing[[canonical_ref.id, label]] ||= ord

            markup = dibur.present? ? { "dibur_hamatchil" => dibur } : {}

            batch << {
              work_id: commentary_work.id,
              canonical_ref_id: canonical_ref.id,
              ord: ord,
              label: label,
              body: body,
              canonical_alignment_type: "exact",
              markup: markup,
              import_run_id: @import_run.id,
              created_at: now,
              updated_at: now
            }

            if batch.size >= BATCH_SIZE
              WorkUnit.upsert_all(batch, unique_by: [:work_id, :ord])
              batch = []
            end
            bump(:"#{layer}_comments")
          end
        end
      end
      WorkUnit.upsert_all(batch, unique_by: [:work_id, :ord]) if batch.any?
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

  end
end
