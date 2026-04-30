require "open-uri"
require "yaml"

module Importers
  # Imports OpenBible.info Topics (curated topic-scores dataset).
  #
  # Source: https://www.openbible.info/topics/
  # Direct: https://a.openbible.info/data/topic-scores.zip
  # License: CC BY 4.0
  # Volume: ~71,000 topic-verse pairs across ~6,700 topics
  #
  # ## Format
  #
  # Tab-separated. Three columns after the header:
  #
  #   Topic                OSIS                       QualityScore
  #   10 commandments      Exod.20.1-Exod.20.26       7
  #   10 commandments      Gal.5.14                   3
  #
  # OSIS is `Book.chapter.verse` or a range across chapters/books. The
  # QualityScore is OpenBible's percentage-of-votes-for-the-passage metric;
  # we keep it as `source_rank` for downstream RRF / weighted scoring.
  #
  # ## Editorial filtering
  #
  # Per `config/openbible_blacklist.yml`, topics on contested social,
  # political, and theological subjects are dropped on the way in (hard
  # skip) — never persisted. The YAML is the audit trail. CC BY 4.0
  # already requires us to indicate when changes are made; the blacklist
  # plus the editorial-policy page satisfy that requirement.
  #
  # ## Idempotency
  #
  # Wipes any existing rows tagged `source = "openbible_topics"` and
  # bulk-inserts. Re-running on the same source produces zero diffs.
  class OpenbibleTopicsImporter < BaseImporter
    SOURCE_URL = "https://a.openbible.info/data/topic-scores.zip"
    SOURCE = "openbible_topics".freeze
    DEFAULT_DIR = Rails.root.join("tmp/openbible_topics")
    BLACKLIST_PATH = Rails.root.join("config/openbible_blacklist.yml")

    # Same map as OpenbibleXrefsImporter — OpenBible's topic-scores file
    # uses the same OSIS-style book codes as their cross-references file.
    BOOK_CODE_TO_KEY = Importers::OpenbibleXrefsImporter::BOOK_CODE_TO_KEY

    REF_RE = /\A([0-9A-Za-z]+)\.(\d+)\.(\d+)\z/

    def initialize(dir: nil, download: nil, **opts)
      super(**opts)
      @dir = Pathname(dir || DEFAULT_DIR)
      @download = download.nil? ? !File.exist?(scores_path) : download
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
      load_blacklist!

      Rails.logger.info "[OpenbibleTopicsImporter] wiping existing rows (source=#{SOURCE})"
      Topic.where(source: SOURCE).destroy_all  # cascades to topic_verses

      @canonical_work_cache = {}
      @ref_cache = {}
      @license_id = License.find_by(spdx_id: "CC-BY-4.0")&.id
      @topic_rows = {}      # name → { display_name:, rows: [{cref_id, score}] }

      Rails.logger.info "[OpenbibleTopicsImporter] parsing #{scores_path}"
      File.open(scores_path, "r:bom|utf-8") do |f|
        f.each_line.with_index do |line, idx|
          next if idx == 0
          line = line.chomp
          next if line.empty? || line.start_with?("#")

          fields = line.split("\t", -1)
          next if fields.length < 3

          process_row(fields)
        end
      end

      flush_topics!
    end

    private

    def scores_path
      @dir.join("topic-scores.txt")
    end

    def zip_path
      @dir.join("topic-scores.zip")
    end

    def ensure_source_present!
      return unless @download || !File.exist?(scores_path)

      Rails.logger.info "[OpenbibleTopicsImporter] downloading #{SOURCE_URL}"
      FileUtils.mkdir_p(@dir)
      URI.open(SOURCE_URL) { |io| File.binwrite(zip_path, io.read) }
      system("unzip", "-o", zip_path.to_s, "-d", @dir.to_s, out: File::NULL) or raise "unzip failed"
      bump(:downloaded)
    end

    def load_blacklist!
      data = YAML.load_file(BLACKLIST_PATH)
      @blacklist = Set.new
      Array(data["contested_topics"]).each do |entry|
        Array(entry["keys"]).each { |k| @blacklist << k.to_s.downcase.strip }
      end
      Rails.logger.info "[OpenbibleTopicsImporter] blacklist: #{@blacklist.size} keys"
    end

    def process_row(fields)
      topic_raw = fields[0].to_s.strip
      osis      = fields[1].to_s.strip
      score     = fields[2].to_f
      return if topic_raw.empty? || osis.empty?

      key = topic_raw.downcase
      if @blacklist.include?(key)
        bump(:rows_blacklisted)
        return
      end

      cref_ids = expand_osis(osis)
      if cref_ids.empty?
        bump(:rows_unresolved)
        return
      end

      bucket = (@topic_rows[key] ||= { display_name: topic_raw, pairs: {} })
      cref_ids.each do |cref_id|
        # Same (topic, cref) may appear from a single-verse row and from
        # a range that includes it — keep the higher score.
        existing = bucket[:pairs][cref_id]
        bucket[:pairs][cref_id] = score if existing.nil? || score > existing
      end
      bump(:rows_processed)
    end

    # Parse OSIS ref or range and expand to a list of canonical_ref ids.
    # Single: "Exod.20.13" → [id]
    # Same-book range: "Exod.20.1-Exod.20.26" → [ids in that ord range]
    # Cross-book range: collapse to start endpoint only.
    def expand_osis(osis)
      if osis.include?("-")
        a, b = osis.split("-", 2)
        sp = parse_ref(a) or return []
        ep = parse_ref(b) or return []

        cw_a = canonical_work_for(sp[0]) or return []
        ord_a = lookup_ord(cw_a, sp[1], sp[2]) or return []

        cw_b = canonical_work_for(ep[0])
        if cw_b&.id == cw_a.id
          ord_b = lookup_ord(cw_b, ep[1], ep[2]) || ord_a
          return [ord_a] if ord_b < ord_a
          CanonicalRef.where(canonical_work_id: cw_a.id, ord: ord_a..ord_b).pluck(:id)
        else
          # Cross-book range — collapse to start.
          bump(:cross_book_range_collapsed)
          [lookup_ref_id(cw_a, sp[1], sp[2])].compact
        end
      else
        sp = parse_ref(osis) or return []
        cw = canonical_work_for(sp[0]) or return []
        [lookup_ref_id(cw, sp[1], sp[2])].compact
      end
    end

    def parse_ref(s)
      m = REF_RE.match(s) or return nil
      [m[1], m[2].to_i, m[3].to_i]
    end

    def canonical_work_for(book_code)
      return @canonical_work_cache[book_code] if @canonical_work_cache.key?(book_code)
      slug = BOOK_CODE_TO_KEY[book_code]
      @canonical_work_cache[book_code] = slug ? CanonicalWork.find_by(slug: slug) : nil
    end

    def lookup_ref_id(cw, chapter, verse)
      key = [cw.id, chapter, verse]
      @ref_cache[key] ||= CanonicalRef.where(canonical_work_id: cw.id, hierarchy: [chapter, verse]).pick(:id)
    end

    def lookup_ord(cw, chapter, verse)
      key = [cw.id, chapter, verse, :ord]
      @ref_cache[key] ||= CanonicalRef.where(canonical_work_id: cw.id, hierarchy: [chapter, verse]).pick(:ord)
    end

    def flush_topics!
      Rails.logger.info "[OpenbibleTopicsImporter] flushing #{@topic_rows.size} topics"
      @topic_rows.each do |name, bucket|
        topic = Topic.create!(
          source: SOURCE,
          source_topic_id: name,
          name: name,
          display_name: bucket[:display_name],
          license_id: @license_id,
          import_run_id: @import_run.id
        )
        bump(:topics_created)

        next if bucket[:pairs].empty?

        rows = bucket[:pairs].map do |cref_id, score|
          {
            topic_id: topic.id,
            canonical_ref_id: cref_id,
            source_rank: score,
            import_run_id: @import_run.id,
            created_at: Time.current,
            updated_at: Time.current
          }
        end
        TopicVerse.insert_all(rows)
        bump(:topic_verses_created, rows.size)
      end
    end
  end
end
