require "nokogiri"
require "open-uri"

module Importers
  # Imports the Brown-Driver-Briggs (BDB) Hebrew Lexicon from
  # OpenScriptures' transcription. Each `<entry>` in BrownDriverBriggs.xml
  # becomes a `lexicon_entries` row, source="BDB". Entries are linked to
  # existing Hebrew lemmas via Strong's numbers from LexicalIndex.xml.
  #
  # Source: https://github.com/openscriptures/HebrewLexicon
  # License: CC BY 4.0 (transcription); BDB itself is public domain (1906).
  # Attribution: "Open Scriptures Hebrew Bible Project" — credited via
  # the lexicon_entries.license_id pointer.
  class BdbImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/oshl")
    SOURCE = "BDB".freeze
    BASE_URL = "https://raw.githubusercontent.com/openscriptures/HebrewLexicon/master".freeze

    def initialize(dir: nil, download: true, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download
    end

    protected

    def source_url
      "https://github.com/openscriptures/HebrewLexicon"
    end

    def source_format
      "xml"
    end

    def transactional?
      false
    end

    def perform
      ensure_files!

      @license_id = License.find_by(spdx_id: "CC-BY-4.0")&.id

      Rails.logger.info "[BdbImporter] wiping existing rows (source=#{SOURCE})"
      LexiconEntry.where(source: SOURCE).delete_all

      bdb_to_strong = parse_lexical_index
      bump(:index_entries, bdb_to_strong.size)

      strong_to_lemma_id = build_strong_to_lemma_index
      bump(:strong_to_lemma_size, strong_to_lemma_id.size)

      doc = Nokogiri::XML(File.read(File.join(@dir, "BrownDriverBriggs.xml")))
      ns = { "ns" => "http://openscriptures.github.com/morphhb/namespace" }
      entries = doc.xpath("//ns:entry", ns)
      Rails.logger.info "[BdbImporter] processing #{entries.size} entries"

      batch = []
      entries.each_with_index do |entry, i|
        row = build_row(entry, ns, bdb_to_strong, strong_to_lemma_id) or next
        batch << row
        bump(:rows_built)
        if batch.size >= 1000
          flush_batch(batch)
        end
        if i % 1000 == 0 && i > 0
          $stdout.puts "[BdbImporter] #{i}/#{entries.size} processed; stats: #{stats.select { |_, v| v > 0 }}"
          $stdout.flush
        end
      end
      flush_batch(batch)
    end

    private

    def ensure_files!
      FileUtils.mkdir_p(@dir)
      %w[BrownDriverBriggs.xml LexicalIndex.xml].each do |name|
        path = File.join(@dir, name)
        next if File.exist?(path) && !@download
        unless File.exist?(path)
          Rails.logger.info "[BdbImporter] downloading #{name}"
          URI.open("#{BASE_URL}/#{name}") { |io| File.binwrite(path, io.read) }
          bump(:files_downloaded)
        end
      end
    end

    # bdb_id (e.g. "a.ac.aa") → { strong: "6", twot: "2", headword: "אָבַד",
    # transliteration: "ʾābad", part_of_speech: "V", gloss: "perish" }
    def parse_lexical_index
      doc = Nokogiri::XML(File.read(File.join(@dir, "LexicalIndex.xml")))
      ns = { "ns" => "http://openscriptures.github.com/morphhb/namespace" }
      result = {}
      doc.xpath("//ns:entry", ns).each do |entry|
        xref = entry.xpath("ns:xref", ns).first or next
        bdb_id = xref["bdb"] or next
        result[bdb_id] = {
          strong: xref["strong"],
          twot: xref["twot"],
          aug_strong: xref["aug"],
          headword: entry.xpath("ns:w", ns).first&.content&.strip,
          transliteration: entry.xpath("ns:w", ns).first&.[]("xlit"),
          part_of_speech: entry.xpath("ns:pos", ns).first&.content&.strip,
          gloss: entry.xpath("ns:def", ns).first&.content&.strip
        }
      end
      result
    end

    # Map "1234" or "H1234" → lemma_id of the most-frequent Hebrew lemma
    # whose words carry that Strong's. Uses the same canonicalization as
    # the on-page Strong's display so we hit existing rows reliably.
    def build_strong_to_lemma_index
      Rails.logger.info "[BdbImporter] building Strong's → lemma index"
      result = {}
      Word.joins(:lemma)
          .where("strongs_number ~ '^[GHgh]?0*[0-9]+0?$'")
          .where(lemmas: { language: %w[he arc] })
          .group(:strongs_number, :lemma_id)
          .count
          .each do |(strongs, lemma_id), count|
        canon = Strongs.normalize(strongs, language: "he")
        next unless canon
        bare = canon[1..]
        prior = result[bare]
        if prior.nil? || prior[:count] < count
          result[bare] = { lemma_id: lemma_id, count: count }
        end
      end
      result.transform_values { |v| v[:lemma_id] }
    end

    def build_row(entry, ns, bdb_to_strong, strong_to_lemma_id)
      bdb_id = entry["id"] or return nil
      headword = entry.xpath("ns:w", ns).first&.content&.strip
      return nil if headword.blank?

      idx = bdb_to_strong[bdb_id] || {}
      strong = idx[:strong]
      lemma_id = strong && strong_to_lemma_id[strong.to_i.to_s]

      bump(:matched_to_lemma) if lemma_id
      bump(:no_lemma_match) unless lemma_id

      meta = {
        bdb_id: bdb_id,
        twot: idx[:twot],
        strong: strong ? "H#{strong.to_i}" : nil,
        entry_type: entry["type"],
        cite: entry["cite"]
      }.compact

      {
        source: SOURCE,
        lemma_id: lemma_id,
        headword: headword,
        normalized: headword.unicode_normalize(:nfc),
        transliteration: idx[:transliteration],
        part_of_speech: idx[:part_of_speech] || entry.xpath("ns:pos", ns).first&.content&.strip,
        summary_gloss: idx[:gloss] || entry.xpath("ns:def", ns).first&.content&.strip,
        body_html: render_entry_html(entry),
        citations: extract_citations(entry, ns),
        meta: meta,
        license_id: @license_id,
        import_run_id: @import_run.id,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    def extract_citations(entry, ns)
      entry.xpath(".//ns:ref", ns).map { |r| r["r"] }.compact.uniq
    end

    # Walk the entry's child nodes and emit reader-friendly HTML.
    # We deliberately drop scrape-internal markup (status, page) and
    # decorate the rest with class hooks the lemma-page CSS targets.
    HE_LANG_TAG = "he".freeze
    def render_entry_html(entry)
      out = +""
      entry.children.each { |c| out << render_node(c) }
      out.strip
    end

    def render_node(node)
      case node
      when Nokogiri::XML::Text
        ERB::Util.h(node.content)
      when Nokogiri::XML::Element
        case node.name
        when "w"
          %(<span class="lex-w" lang="#{HE_LANG_TAG}">#{render_children(node)}</span>)
        when "def"
          %(<span class="lex-def">#{render_children(node)}</span>)
        when "pos"
          %(<span class="lex-pos">#{render_children(node)}</span>)
        when "asp", "stem"
          %(<span class="lex-#{node.name}">#{render_children(node)}</span>)
        when "em"
          %(<em>#{render_children(node)}</em>)
        when "ref"
          ref = node["r"].to_s
          %(<a class="lex-ref" data-ref="#{ERB::Util.h(ref)}">#{render_children(node)}</a>)
        when "foreign"
          lang = node["xml:lang"] || node["lang"]
          %(<span class="lex-foreign"#{lang ? " lang=\"#{ERB::Util.h(lang)}\"" : ""}>#{render_children(node)}</span>)
        when "sense"
          n = node["n"]
          %(<div class="lex-sense"#{n ? " data-n=\"#{ERB::Util.h(n)}\"" : ""}>#{render_children(node)}</div>)
        when "page", "status"
          ""  # drop scrape-internal markers
        else
          render_children(node)  # unknown markup: pass content through
        end
      else
        ""  # comments, etc.
      end
    end

    def render_children(node)
      node.children.map { |c| render_node(c) }.join
    end

    def flush_batch(batch)
      return if batch.empty?
      LexiconEntry.insert_all(batch)
      bump(:entries_inserted, batch.size)
      batch.clear
    end
  end
end
