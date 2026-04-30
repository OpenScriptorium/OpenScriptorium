require "open-uri"
require "json"

module Importers
  # Imports Sefaria topical index, filtered to Tanakh refs only.
  #
  # Source:
  #   - https://www.sefaria.org/api/topics?limit=0&minify=0   (topic metadata, all)
  #   - https://www.sefaria.org/api/topics/<slug>?with_refs=1  (refs per topic)
  # License: CC BY 4.0 (Sefaria's data license; attribution required)
  # Volume: ~5,200 topics; Tanakh-relevant subset is smaller (~1-2k expected)
  #
  # ## Why Tanakh-only
  #
  # The audit showed Sefaria's value here is as a counterweight to OpenBible's
  # evangelical bias on contested topics. That counterweight only applies for
  # questions Sefaria has Tanakh refs for. Talmud/Mishnah refs are a different
  # search UX and add addressing complexity (daf+amud+segment) — out of scope
  # for the topical-index layer for now.
  #
  # ## Politeness + caching
  #
  # ~5,200 topics → ~5,200 API calls. We cache each response to
  # `tmp/sefaria_topics/refs/<slug>.json` so re-runs and partial runs reuse
  # what's already on disk. Set REFRESH=true to force re-fetch.
  #
  # ## Idempotency
  #
  # Wipes any existing rows tagged `source = "sefaria_topics"` and bulk-inserts.
  class SefariaTopicsImporter < BaseImporter
    METADATA_URL = "https://www.sefaria.org/api/topics?limit=0&minify=0"
    TOPIC_URL    = "https://www.sefaria.org/api/topics/%s?with_refs=1"
    SOURCE = "sefaria_topics".freeze
    DEFAULT_DIR = Rails.root.join("tmp/sefaria_topics")
    POLITE_DELAY = 0.15  # seconds between API calls
    USER_AGENT = "openscriptorium-importer (skush97@gmail.com)".freeze

    # Tanakh-only subset of SefariaLinksImporter::SEFARIA_TO_SLUG.
    SEFARIA_BOOK_TO_SLUG = {
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

    # Sort books by length descending so "I Samuel" matches before "I" (irrelevant
    # here, but the longest-first rule is right for reference parsing in general).
    SORTED_BOOK_NAMES = SEFARIA_BOOK_TO_SLUG.keys.sort_by { |k| -k.length }.freeze

    REF_RE = /\A(?<book>.+?)\s+(?<ch>\d+):(?<v>\d+)(?:-(?:\d+:)?(?<ev>\d+))?\z/

    def initialize(refresh: false, **opts)
      super(**opts)
      @refresh = refresh
      @dir = DEFAULT_DIR
      @refs_dir = @dir.join("refs")
    end

    protected

    def source_url
      "https://www.sefaria.org/topics/"
    end

    def source_format
      "json (api)"
    end

    def transactional?
      false
    end

    def perform
      FileUtils.mkdir_p(@refs_dir)
      ensure_metadata!
      load_blacklist!  # currently empty; placeholder for future curation

      Rails.logger.info "[SefariaTopicsImporter] wiping existing rows (source=#{SOURCE})"
      Topic.where(source: SOURCE).destroy_all

      @canonical_work_cache = {}
      @ref_cache = {}
      @license_id = License.find_by(spdx_id: "CC-BY-4.0")&.id

      metadata = JSON.parse(File.read(metadata_path))
      Rails.logger.info "[SefariaTopicsImporter] processing #{metadata.size} topics"

      metadata.each_with_index do |entry, i|
        slug = entry["slug"]
        next if slug.nil? || slug.empty?
        next unless entry.fetch("shouldDisplay", true)

        # Note: bulk metadata dump strips `numSources`; we can't pre-filter
        # by source count. Topics without Tanakh refs will auto-skip via
        # `topics_no_tanakh_refs` after fetch + parse.

        process_topic(entry, slug)

        if i % 250 == 0 && i > 0
          $stdout.puts "[SefariaTopicsImporter] #{i}/#{metadata.size} processed; stats: #{stats.select { |_, v| v > 0 }}"
          $stdout.flush
        end
      end
    end

    private

    def metadata_path
      @dir.join("topics.json")
    end

    def ensure_metadata!
      if @refresh || !File.exist?(metadata_path)
        Rails.logger.info "[SefariaTopicsImporter] downloading metadata from #{METADATA_URL}"
        URI.open(METADATA_URL, "User-Agent" => USER_AGENT) { |io| File.binwrite(metadata_path, io.read) }
        bump(:metadata_downloaded)
      end
    end

    def load_blacklist!
      # Sefaria aligned with academic-critical consensus in the audit; no blanket
      # blacklist needed. Placeholder so adding one later is a one-line change.
      @blacklist = Set.new
    end

    def process_topic(entry, slug)
      # `||` doesn't help with empty strings (truthy in Ruby) — use .presence.
      en_title = entry.dig("primaryTitle", "en").presence || entry["en"].presence
      if en_title.nil?
        # Hebrew-only topics: not queryable in English; skip rather than
        # surface a Hebrew slug in our English topical index.
        bump(:topics_no_english_title)
        return
      end
      key = en_title.downcase.strip
      if @blacklist.include?(key)
        bump(:topics_blacklisted)
        return
      end

      data = fetch_topic_refs(slug)
      return unless data

      refs = Array(data["refs"])
      tanakh_pairs = []  # [cref_id, source_rank]

      refs.each do |r|
        ref_str = r["ref"].to_s
        cref_id = parse_and_lookup(ref_str) or next
        rank = r.dig("order", "pr") || r.dig("order", "tfidf") || 0.0
        tanakh_pairs << [cref_id, rank]
      end

      if tanakh_pairs.empty?
        bump(:topics_no_tanakh_refs)
        return
      end

      # De-dup: same canonical_ref might appear from multiple Sefaria refs
      # that all map to the same canonical verse — keep the highest rank.
      best = {}
      tanakh_pairs.each do |cref_id, rank|
        existing = best[cref_id]
        best[cref_id] = rank if existing.nil? || rank > existing
      end

      topic = Topic.create!(
        source: SOURCE,
        source_topic_id: slug,
        name: key,
        display_name: en_title,
        description: extract_description(entry),
        license_id: @license_id,
        import_run_id: @import_run.id
      )
      bump(:topics_created)

      rows = best.map do |cref_id, rank|
        {
          topic_id: topic.id,
          canonical_ref_id: cref_id,
          source_rank: rank.to_f,
          import_run_id: @import_run.id,
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      TopicVerse.insert_all(rows)
      bump(:topic_verses_created, rows.size)
    end

    def extract_description(entry)
      desc = entry["description"]
      case desc
      when Hash then desc["en"]
      when String then desc
      end&.then { |s| s.empty? ? nil : s }
    end

    def fetch_topic_refs(slug)
      @refs_dir.mkpath unless @refs_dir.exist?
      cache_path = @refs_dir.join("#{slug}.json")
      if !@refresh && File.exist?(cache_path)
        return JSON.parse(File.read(cache_path))
      end

      url = format(TOPIC_URL, ERB::Util.url_encode(slug))
      sleep POLITE_DELAY
      body = URI.open(url, "User-Agent" => USER_AGENT, read_timeout: 30, &:read)
      File.binwrite(cache_path, body)
      bump(:topics_fetched)
      JSON.parse(body)
    rescue OpenURI::HTTPError => e
      Rails.logger.warn "[SefariaTopicsImporter] HTTP #{e.message} for #{slug}"
      bump(:fetch_errors)
      nil
    rescue => e
      Rails.logger.warn "[SefariaTopicsImporter] #{e.class}: #{e.message} for #{slug}"
      bump(:fetch_errors)
      nil
    end

    # "Genesis 1:1" → cref_id; "Numbers 27:1-7" → cref_id (start only)
    # "Mishnah Oholot 7:6", "Berakhot 2a:3" → nil (skipped, non-Tanakh)
    def parse_and_lookup(ref_str)
      m = REF_RE.match(ref_str) or return nil
      book_full = m[:book].strip
      slug = SEFARIA_BOOK_TO_SLUG[book_full] or return nil

      cw = canonical_work_for(slug) or return nil
      lookup_ref_id(cw, m[:ch].to_i, m[:v].to_i)
    end

    def canonical_work_for(slug)
      return @canonical_work_cache[slug] if @canonical_work_cache.key?(slug)
      @canonical_work_cache[slug] = CanonicalWork.find_by(slug: slug)
    end

    def lookup_ref_id(cw, chapter, verse)
      key = [cw.id, chapter, verse]
      @ref_cache[key] ||= CanonicalRef.where(canonical_work_id: cw.id, hierarchy: [chapter, verse]).pick(:id)
    end
  end
end
