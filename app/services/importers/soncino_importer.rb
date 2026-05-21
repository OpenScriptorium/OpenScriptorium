module Importers
  # Imports the Soncino English Translation of the Babylonian Talmud
  # (ed. Rabbi Dr. Isidore Epstein, Soncino Press, 1935–1948).
  #
  # Source: halakhah.com (HTML for 15 tractates, PDF for the rest).
  # The text is PD in Canada (corporate copyright expired by 1998).
  #
  # Alignment: one work_unit per amud (daf side), aligned to the first
  # canonical_ref for that daf+amud. Same approach as VilnaMarginsImporter.
  class SoncinoImporter < BaseImporter
    HTML_DIR = Rails.root.join("tmp/soncino/html")
    PDF_DIR  = Rails.root.join("tmp/soncino/pdf")
    TXT_DIR  = Rails.root.join("tmp/soncino/txt")

    # Map our canonical_work slugs to halakhah.com URL paths (HTML tractates)
    HTML_TRACTATES = {
      "berakhot"     => { url_base: "berakoth",    url_name: "berakoth",    start_daf: 2 },
      "shabbat"      => { url_base: "shabbath",    url_name: "shabbath",    start_daf: 2 },
      "yevamot"      => { url_base: "yebamoth",    url_name: "yebamoth",   start_daf: 2 },
      "ketubot"      => { url_base: "kethuboth",   url_name: "kethuboth",  start_daf: 2 },
      "nedarim"      => { url_base: "nedarim",     url_name: "nedarim",    start_daf: 2 },
      "nazir"        => { url_base: "nazir",       url_name: "nazir",      start_daf: 2 },
      "sotah"        => { url_base: "sotah",       url_name: "sotah",      start_daf: 2 },
      "gittin"       => { url_base: "gittin",      url_name: "gittin",     start_daf: 2 },
      "bava-kamma"   => { url_base: "babakamma",   url_name: "babakamma",  start_daf: 2 },
      "bava-metzia"  => { url_base: "babamezia",   url_name: "babamezia",  start_daf: 2 },
      "bava-batra"   => { url_base: "bababathra",  url_name: "bababathra", start_daf: 2 },
      "sanhedrin"    => { url_base: "sanhedrin",    url_name: "sanhedrin",  start_daf: 2 },
      "avodah-zarah" => { url_base: "zarah",       url_name: "zarah",      start_daf: 2 },
      "horayot"      => { url_base: "horayoth",    url_name: "horayoth",   start_daf: 2 },
      "niddah"       => { url_base: "niddah",      url_name: "niddah",     start_daf: 2 },
    }.freeze

    # PDF tractates (all the rest)
    PDF_TRACTATES = {
      "eruvin"       => "eruvin",
      "pesachim"     => "pesachim",
      "yoma"         => "yoma",
      "sukkah"       => "sukkah",
      "beitzah"      => "beitzah",
      "rosh-hashanah" => "rosh-hashanah",
      "taanit"       => "taanit",
      "megillah"     => "megillah",
      "moed-katan"   => "moed-katan",
      "chagigah"     => "chagigah",
      "kiddushin"    => "kiddushin",
      "shevuot"      => "shevuot",
      "makkot"       => "makkot",
      "zevachim"     => "zevachim",
      "menachot"     => "menachot",
      "chullin"      => "chullin",
      "bekhorot"     => "bekhorot",
      "arakhin"      => "arakhin",
      "temurah"      => "temurah",
      "keritot"      => "keritot",
      "meilah"       => "meilah",
      "tamid"        => "tamid",
    }.freeze

    def initialize(download: true, **opts)
      super(**opts)
      @download = download
    end

    protected

    def source_url
      "https://halakhah.com/"
    end

    def source_format
      "html+pdf"
    end

    def transactional?
      false
    end

    def perform
      @pd = License.find_by!(name: "Public Domain")
      @bavli_scheme = VersificationScheme.find_by!(code: "Bavli")
      @work = ensure_work
      @cw_cache = {}
      @ord = WorkUnit.where(work_id: @work.id).maximum(:ord) || 0

      # Wipe for idempotency (work_units + their notes)
      wu_ids = WorkUnit.where(work_id: @work.id).pluck(:id)
      WorkUnitNote.where(work_unit_id: wu_ids).delete_all if wu_ids.any?
      WorkUnit.where(work_id: @work.id).delete_all
      @ord = 0

      HTML_TRACTATES.each do |slug, info|
        download_html(slug, info) if @download
        import_html_tractate(slug, info)
      end

      PDF_TRACTATES.each do |slug, pdf_name|
        import_pdf_tractate(slug, pdf_name)
      end

      @work.update!(imported_at: Time.current, last_imported_at: Time.current)
    end

    private

    def ensure_work
      Work.find_or_initialize_by(slug: "soncino-bavli").tap do |w|
        w.assign_attributes(
          title: "Soncino English Talmud",
          native_title: nil,
          work_type: "commentary",
          language: "en",
          traditions: ["ש-rabbinic"],
          genre: "commentary",
          license: @pd,
          default_versification_scheme: @bavli_scheme,
          source_url: "https://halakhah.com/",
          has_word_data: false,
          description: "English translation of the Babylonian Talmud, ed. Rabbi Dr. Isidore Epstein, " \
                       "Soncino Press, 1935–1948. Public domain in Canada."
        )
        stamp(w)
        w.save!
      end
    end

    # ── HTML parsing ──────────────────────────────────────────────

    def download_html(slug, info)
      dir = HTML_DIR.join(info[:url_base])
      FileUtils.mkdir_p(dir)

      cw = find_canonical_work(slug)
      return unless cw

      max_daf = CanonicalRef.where(canonical_work_id: cw.id).maximum("hierarchy[1]") || 2
      (info[:start_daf]..max_daf).each do |daf|
        file = dir.join("#{info[:url_name]}_#{daf}.html")
        next if File.exist?(file)
        url = "https://halakhah.com/#{info[:url_base]}/#{info[:url_name]}_#{daf}.html"
        begin
          content = fetch_with_retries(url)
          File.write(file, content)
          bump(:html_downloaded)
        rescue OpenURI::HTTPError
          # Some dafim may not exist (404)
          bump(:html_missing)
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError => e
          # Network blip after retries — log and skip; this daf will be
          # retried on the next run since File.exist? above gates the
          # download.
          Rails.logger.warn "[SoncinoImporter] giving up on #{info[:url_name]}_#{daf}: #{e.class}: #{e.message}"
          bump(:html_network_skipped)
        end
        sleep 0.2 # be polite
      end
    end

    def fetch_with_retries(url, attempts: 3)
      tries = 0
      begin
        tries += 1
        URI.open(url, open_timeout: 30, read_timeout: 60).read
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError => e
        if tries < attempts
          sleep 2 * tries  # 2s, 4s
          retry
        end
        raise
      end
    end

    def import_html_tractate(slug, info)
      cw = find_canonical_work(slug)
      return unless cw

      dir = HTML_DIR.join(info[:url_base])
      return unless File.directory?(dir)

      Dir.glob(dir.join("#{info[:url_name]}_*.html")).sort_by { |f|
        f[/(\d+)\.html/, 1].to_i
      }.each do |path|
        parse_html_file(path, cw)
      end
      bump(:html_tractates)
    end

    def parse_html_file(path, cw)
      require "nokogiri"
      raw = File.read(path, encoding: "binary")
      html = raw.encode("UTF-8", "ISO-8859-1", invalid: :replace, undef: :replace, replace: "")
      doc = Nokogiri::HTML(html)

      # First pass: extract all footnotes keyed by anchor name (e.g. "2a_1")
      footnotes = {}
      doc.css("ol li").each do |li|
        anchor = li.at_css("a[name]")
        next unless anchor
        key = anchor["name"]  # e.g. "2a_1", "2b_3"
        text = li.text.gsub(/\s+/, " ").strip
        footnotes[key] = text unless text.empty?
      end

      # Second pass: extract body text, split by daf markers
      current_daf = nil
      current_amud = nil
      current_text = []
      current_footnote_keys = []

      just_saved_partb = false

      doc.css("body *").each do |node|
        # Daf marker: <h3>Folio 2a</h3> or <h3>Berakoth 2b</h3>
        if node.name == "h3"
          h3_text = node.text.strip
          if h3_text.match?(/(\d+)([ab])\s*\z/i)
            m = h3_text.match(/(\d+)([ab])\s*\z/i)
            new_daf = m[1].to_i
            new_amud = m[2].downcase == "a" ? 1 : 2

            # Skip if PARTb already saved this transition (avoids double-save
            # that loses footnote keys)
            unless just_saved_partb && new_daf == current_daf && new_amud == current_amud
              save_amud(cw, current_daf, current_amud, current_text, current_footnote_keys, footnotes) if current_daf
              current_text = []
              current_footnote_keys = []
            end

            current_daf = new_daf
            current_amud = new_amud
            just_saved_partb = false
            next
          end
        end

        # PARTb anchor marks the transition to amud b
        if node.name == "a" && node["name"] == "PARTb"
          save_amud(cw, current_daf, current_amud, current_text, current_footnote_keys, footnotes) if current_daf
          current_amud = 2
          current_text = []
          current_footnote_keys = []
          just_saved_partb = true
          next
        end

        # Skip OL elements (footnote lists) — already extracted above
        next if node.name == "ol" || node.ancestors("ol").any?

        # Skip content after <hr width="50%"> (footnote section separator)
        next if node.name == "hr"

        # Collect text from <p> elements only
        next unless node.name == "p" && current_daf

        # Capture footnote keys referenced in this paragraph
        node.css("a[href^='#']").each do |a|
          ref = a["href"]&.sub("#", "")
          current_footnote_keys << ref if ref && footnotes[ref]
        end

        clean = node.inner_html
          .gsub(/<a[^>]*><sup>\d+<\/sup><\/a>\s*/, "")  # strip footnote markers
          .gsub(/<[^>]+>/, "")                            # strip all tags
          .gsub(/&[a-z]+;/, " ")                          # entities
          .gsub(/,(\d+)/, ",")                            # strip bare number after comma (inline refs like ",1")
          .gsub(/\s+/, " ").strip
        current_text << clean unless clean.empty?
      end

      save_amud(cw, current_daf, current_amud, current_text, current_footnote_keys, footnotes) if current_daf
    end

    # ── PDF parsing ───────────────────────────────────────────────

    def import_pdf_tractate(slug, pdf_name)
      cw = find_canonical_work(slug)
      return unless cw

      # Try pre-extracted text file first, then pdftotext
      txt_path = TXT_DIR.join("#{pdf_name}.txt")
      if File.exist?(txt_path)
        text = File.read(txt_path, encoding: "UTF-8")
      else
        pdf_path = PDF_DIR.join("#{pdf_name}.pdf")
        return unless File.exist?(pdf_path)
        text = `pdftotext #{pdf_path.to_s.shellescape} - 2>/dev/null`
      end
      return if text.empty?

      parse_pdf_text(text, cw, slug)
      bump(:pdf_tractates)
    end

    def parse_pdf_text(text, cw, slug)
      current_daf = nil
      current_amud = nil
      current_lines = []
      current_footnotes = []
      in_footnotes = false

      text.each_line do |line|
        line = line.strip

        # Daf header: "Talmud - Mas. Pesachim 2a" or "Talmud - Mas. Pesachim 2b"
        if line.match?(/\ATalmud\s*-\s*Mas\.\s+.+\s+(\d+)([ab])\s*\z/i)
          m = line.match(/(\d+)([ab])\s*\z/i)
          save_amud(cw, current_daf, current_amud, current_lines, nil, nil, current_footnotes) if current_daf
          current_daf = m[1].to_i
          current_amud = m[2].downcase == "a" ? 1 : 2
          current_lines = []
          current_footnotes = []
          in_footnotes = false
          next
        end

        # Footnote section starts with ____ line
        if line.match?(/\A_+\z/)
          in_footnotes = true
          next
        end

        # Skip chapter headers
        next if line.match?(/\ACHAPTER\s+[IVXLC]+\s*\z/)

        # Skip empty lines
        next if line.empty?

        if in_footnotes
          # Footnote line: "(1) text..." or continuation of previous footnote
          if line.match?(/\A\((\d+)\)\s*(.*)/)
            m = line.match(/\A\((\d+)\)\s*(.*)/)
            current_footnotes << { number: m[1].to_i, text: m[2] }
          elsif current_footnotes.any?
            # Continuation of previous footnote
            current_footnotes.last[:text] += " " + line
          end
        else
          # Strip inline footnote numbers from body text
          cleaned = line.gsub(/(\w),(\d+)/, '\1,')  # "word,1" → "word,"
                        .gsub(/(\w)(\d+)(\s)/, '\1\3')  # "word1 " → "word " (bare trailing numbers)
          current_lines << cleaned if current_daf
        end
      end

      save_amud(cw, current_daf, current_amud, current_lines, nil, nil, current_footnotes) if current_daf
    end

    # ── Shared ────────────────────────────────────────────────────

    # HTML path: footnote_keys + footnotes_hash
    # PDF path: pdf_footnotes (array of {number:, text:})
    def save_amud(cw, daf, amud, text_parts, footnote_keys = nil, footnotes_hash = nil, pdf_footnotes = nil)
      return if text_parts.empty? || daf.nil? || amud.nil?

      cref = CanonicalRef.where(canonical_work_id: cw.id)
               .where("hierarchy[1] = ? AND hierarchy[2] = ?", daf, amud)
               .order(:ord).first
      return unless cref

      body = text_parts.join(" ")
               .gsub(/\s*\d+\s*(?=[,.\s])/, " ")  # strip orphaned inline numbers
               .gsub(/\s+/, " ").strip
      return if body.empty?

      label = "#{daf}#{amud == 1 ? 'a' : 'b'}"
      @ord += 1

      wu = WorkUnit.create!(
        work_id: @work.id,
        canonical_ref_id: cref.id,
        ord: @ord,
        label: label,
        body: body,
        canonical_alignment_type: "approximate",
        import_run_id: @import_run.id
      )
      bump(:amudim_created)

      # Attach footnotes from HTML
      if footnote_keys&.any? && footnotes_hash
        footnote_keys.uniq.each_with_index do |key, idx|
          text = footnotes_hash[key]
          next unless text.present?
          WorkUnitNote.create!(
            work_unit_id: wu.id,
            position_in_unit: idx,
            note_type: "explanation",
            body: text,
            import_run_id: @import_run.id
          )
          bump(:notes_created)
        end
      end

      # Attach footnotes from PDF
      if pdf_footnotes&.any?
        pdf_footnotes.each_with_index do |fn, idx|
          text = fn[:text].to_s.gsub(/\s+/, " ").strip
          next if text.empty?
          WorkUnitNote.create!(
            work_unit_id: wu.id,
            position_in_unit: idx,
            note_type: "explanation",
            body: text,
            import_run_id: @import_run.id
          )
          bump(:notes_created)
        end
      end
    end

    def find_canonical_work(slug)
      @cw_cache[slug] ||= CanonicalWork.find_by(slug: slug)
    end
  end
end
