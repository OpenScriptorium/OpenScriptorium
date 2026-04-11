module Importers
  # Imports the Vilna margin commentaries from Sefaria exports.
  #
  # These are the texts that appear in the margins of the printed
  # Vilna Shas around the Gemara, Rashi, and Tosafot:
  #
  #   - Gilyon HaShas (R' Akiva Eger, 19th c.)
  #   - Rashash (R' Shmuel Strashun, 19th c.)
  #   - Maharsha Chidushei Halachot (R' Shmuel Eidels, 17th c.)
  #   - Maharsha Chidushei Agadot (same author)
  #   - Chokhmat Shlomo (R' Shlomo Luria, 16th c.)
  #   - Hagahot Ya'avetz (R' Yaakov Emden, 18th c.)
  #   - Piskei Tosafot (medieval, summarizes Tosafot rulings)
  #
  # All are Public Domain (Vilna Edition, 1880s).
  # Data format: 2D [Daf][Comment] — keyed to daf level, not segment.
  #
  # Each commentary becomes its own Work. Work_units align to
  # canonical_refs at the [daf, amud, 1] level (first segment of
  # the amud) since the source data doesn't specify finer alignment.
  class VilnaMarginsImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/sefaria")

    COMMENTARIES = [
      {
        dir: "gilyon-hashas",
        slug: "gilyon-hashas",
        title: "Gilyon HaShas",
        native_title: "גליון הש״ס",
        author_desc: "R' Akiva Eger (19th c.)",
      },
      {
        dir: "rashash",
        slug: "rashash-bavli",
        title: "Rashash on Talmud Bavli",
        native_title: "רשש״ש",
        author_desc: "R' Shmuel Strashun (19th c.)",
      },
      {
        dir: "maharsha-halachot",
        slug: "maharsha-halachot",
        title: "Maharsha Chidushei Halachot",
        native_title: "מהרש״א חידושי הלכות",
        author_desc: "R' Shmuel Eidels (17th c.)",
      },
      {
        dir: "maharsha-agadot",
        slug: "maharsha-agadot",
        title: "Maharsha Chidushei Agadot",
        native_title: "מהרש״א חידושי אגדות",
        author_desc: "R' Shmuel Eidels (17th c.)",
      },
      {
        dir: "chokhmat-shlomo",
        slug: "chokhmat-shlomo",
        title: "Chokhmat Shlomo",
        native_title: "חכמת שלמה",
        author_desc: "R' Shlomo Luria (16th c.)",
      },
      {
        dir: "hagahot-yaavetz",
        slug: "hagahot-yaavetz",
        title: "Hagahot Ya'avetz",
        native_title: "הגהות יעב״ץ",
        author_desc: "R' Yaakov Emden (18th c.)",
      },
      {
        dir: "piskei-tosafot",
        slug: "piskei-tosafot",
        title: "Piskei Tosafot",
        native_title: "פסקי תוספות",
        author_desc: "Medieval (summarizes Tosafot rulings)",
      },
    ].freeze

    # Map Sefaria tractate filenames to our canonical_work slugs
    TRACTATE_MAP = BavliImporter::TRACTATES.map { |t| [t[0], t[1]] }.to_h

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
      @pd = License.find_by!(name: "Public Domain")
      @bavli_scheme = VersificationScheme.find_by!(code: "Bavli")
      @cw_cache = {}

      COMMENTARIES.each do |commentary|
        import_commentary(commentary)
      end
    end

    private

    def import_commentary(commentary)
      work = ensure_work(commentary)
      data_dir = File.join(@dir, commentary[:dir])
      return unless File.directory?(data_dir)

      Dir.glob(File.join(data_dir, "*.json")).sort.each do |path|
        tractate_slug = File.basename(path, ".json")
        our_slug = TRACTATE_MAP[tractate_slug]
        next unless our_slug

        canonical_work = find_canonical_work(our_slug)
        next unless canonical_work

        data = JSON.parse(File.read(path))
        section_names = data["sectionNames"] || []

        if section_names == ["Daf", "Comment"]
          import_daf_comment(work, canonical_work, data["text"])
        elsif section_names == ["Comment", "Paragraph"]
          import_comment_paragraph(work, canonical_work, data["text"])
        end

        bump(:tractates_processed)
      end

      work.update!(last_imported_at: Time.current,
                   imported_at: work.imported_at || Time.current)
      bump(:commentaries_imported)
    end

    # 2D format: text[daf_index] = [comment1, comment2, ...]
    def import_daf_comment(work, canonical_work, text_array)
      text_array.each_with_index do |comments, index|
        next unless comments.is_a?(Array)

        daf = (index / 2) + 1
        amud = (index % 2 == 0) ? 1 : 2

        # Find first canonical_ref for this daf+amud
        cref = CanonicalRef.where(
          canonical_work_id: canonical_work.id
        ).where("hierarchy[1] = ? AND hierarchy[2] = ?", daf, amud)
         .order(:ord).first
        next unless cref

        comments.each_with_index do |comment_html, ci|
          next if comment_html.nil? || comment_html.to_s.strip.empty?

          body = strip_html(comment_html)
          next if body.empty?

          label = "#{daf}#{amud == 1 ? 'a' : 'b'}.#{ci + 1}"
          wu = WorkUnit.find_or_initialize_by(
            work_id: work.id, canonical_ref_id: cref.id, label: label
          )
          if wu.new_record?
            wu.assign_attributes(
              ord: next_ord(work.id),
              canonical_alignment_type: "approximate"
            )
          end
          wu.body = body
          stamp(wu)
          wu.save!
          bump(:comments_created)
        end
      end
    end

    # Piskei Tosafot format: text[comment_index] = [paragraph1, ...]
    def import_comment_paragraph(work, canonical_work, text_array)
      # This format doesn't have daf addressing — it's sequential.
      # We'll assign to the first canonical_ref of the tractate.
      cref = CanonicalRef.where(canonical_work_id: canonical_work.id)
                         .order(:ord).first
      return unless cref

      text_array.each_with_index do |paragraphs, ci|
        next unless paragraphs.is_a?(Array)
        body = paragraphs.map { |p| strip_html(p.to_s) }.reject(&:empty?).join(" ")
        next if body.empty?

        label = "#{ci + 1}"
        wu = WorkUnit.find_or_initialize_by(
          work_id: work.id, canonical_ref_id: cref.id, label: label
        )
        if wu.new_record?
          wu.assign_attributes(
            ord: next_ord(work.id),
            canonical_alignment_type: "approximate"
          )
        end
        wu.body = body
        stamp(wu)
        wu.save!
        bump(:comments_created)
      end
    end

    def ensure_work(commentary)
      Work.find_or_initialize_by(slug: commentary[:slug]).tap do |w|
        w.assign_attributes(
          title: commentary[:title],
          native_title: commentary[:native_title],
          work_type: "commentary",
          language: "arc",
          traditions: ["ש-rabbinic"],
          genre: "commentary",
          license: @pd,
          default_versification_scheme: @bavli_scheme,
          source_url: "https://www.sefaria.org/",
          has_word_data: false,
          description: "#{commentary[:title]} — #{commentary[:author_desc]}. " \
                       "Vilna edition marginal commentary on the Babylonian Talmud. Public domain."
        )
        stamp(w)
        w.save!
      end
    end

    def find_canonical_work(slug)
      @cw_cache[slug] ||= CanonicalWork.find_by(slug: slug)
    end

    def strip_html(html)
      html.to_s
        .gsub(/<[^>]+>/, "")
        .gsub(/&amp;/, "&").gsub(/&lt;/, "<").gsub(/&gt;/, ">")
        .gsub(/&nbsp;/, " ").gsub(/&quot;/, '"')
        .gsub(/\s+/, " ").strip
    end

    def next_ord(work_id)
      @ord_counters ||= {}
      @ord_counters[work_id] ||= (WorkUnit.where(work_id: work_id).maximum(:ord) || 0)
      @ord_counters[work_id] += 1
    end
  end
end
