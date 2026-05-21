require "nokogiri"

module Importers
  # Imports the Liddell-Scott-Jones Greek-English Lexicon (LSJ) from
  # Perseus's TEI XML. Each `<entryFree>` becomes a `lexicon_entries`
  # row, source="LSJ". Entries link to existing Greek lemmas by Unicode
  # headword (after Beta-Code → Unicode conversion + NFC normalization).
  #
  # LSJ has ~110K entries covering all of classical Greek. Most won't
  # match a lemma in our (NT/LXX-focused) corpus — those stay as
  # browseable LexiconEntry rows with lemma_id = nil. Matched entries
  # surface on the lemma show page and as enriched popover content.
  #
  # Source: https://github.com/PerseusDL/lexica
  # License: CC BY-SA 4.0
  class LsjImporter < BaseImporter
    REPO_ROOT = Rails.root.join("tmp/lsj_src")
    DEFAULT_DIR = REPO_ROOT.join("CTS_XML_TEI/perseus/pdllex/grc/lsj")
    SOURCE = "LSJ".freeze
    SOURCE_REPO_URL = "https://github.com/PerseusDL/lexica.git".freeze

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://github.com/PerseusDL/lexica"
    end

    def source_format
      "tei-xml"
    end

    def transactional?
      false
    end

    def perform
      download_source if Dir.glob(File.join(@dir, "*.xml")).empty?

      @license_id = License.find_by(spdx_id: "CC-BY-SA-4.0")&.id

      Rails.logger.info "[LsjImporter] wiping existing rows (source=#{SOURCE})"
      LexiconEntry.where(source: SOURCE).delete_all

      @lemma_index = build_greek_lemma_index
      bump(:lemma_index_size, @lemma_index.size)

      files = Dir.glob(File.join(@dir, "*.xml")).sort
      Rails.logger.info "[LsjImporter] processing #{files.size} files"

      batch = []
      files.each_with_index do |path, fi|
        Rails.logger.info "[LsjImporter] file #{fi + 1}/#{files.size}: #{File.basename(path)}"
        doc = Nokogiri::XML(File.open(path))
        doc.xpath("//entryFree").each do |entry|
          row = build_row(entry) or next
          batch << row
          bump(:rows_built)
          if batch.size >= 1000
            flush_batch(batch)
          end
        end
        $stdout.puts "[LsjImporter] file #{fi + 1} done; cumulative: #{stats.select { |_, v| v > 0 }}"
        $stdout.flush
      end
      flush_batch(batch)
    end

    # Sparse-checkout PerseusDL/lexica to fetch only the LSJ TEI XML
    # subtree. Without sparse-checkout the repo is several hundred MB.
    def download_source
      FileUtils.mkdir_p(REPO_ROOT)
      Rails.logger.info "[LsjImporter] sparse-cloning #{SOURCE_REPO_URL}"
      Dir.chdir(REPO_ROOT) do
        system("git", "init", "-q", exception: true)
        system("git", "remote", "add", "origin", SOURCE_REPO_URL, exception: false)
        system("git", "config", "core.sparseCheckout", "true", exception: true)
        File.write(File.join(REPO_ROOT, ".git/info/sparse-checkout"),
                   "CTS_XML_TEI/perseus/pdllex/grc/lsj/\n")
        system("git", "pull", "--depth", "1", "origin", "master", exception: true)
      end
      bump(:source_downloaded)
    end

    private

    # Greek-Unicode-headword → lemma_id, for matching LSJ entries to
    # existing lemmas. Includes both NFC-normalized exact forms and a
    # diacritic-stripped fallback (LSJ orth doesn't always include
    # breathing/accents that our lemma table has).
    def build_greek_lemma_index
      idx = {}
      Lemma.where(language: %w[el el-koine])
           .where.not(lemma: nil)
           .pluck(:id, :lemma)
           .each do |id, lemma|
        next if lemma.blank?
        idx[lemma.unicode_normalize(:nfc)] ||= id
        idx[strip_diacritics(lemma).downcase] ||= id
      end
      idx
    end

    def strip_diacritics(s)
      s.unicode_normalize(:nfd).gsub(/[\p{Mn}]/, "").unicode_normalize(:nfc)
    end

    def build_row(entry)
      orth = entry.xpath(".//orth").first
      return nil unless orth
      orth_beta = orth.content.to_s.strip
      return nil if orth_beta.empty?

      raw_headword = BetaCode.to_unicode(orth_beta)
      # LSJ uses editorial hyphens like "ἀγαπ-ησμός" to mark continuation
      # entries that share a prefix with the previous main entry. Strip
      # them so we display and match against the bare Greek word.
      headword = raw_headword.tr("-‐‑", "").strip
      return nil if headword.empty?

      lemma_id = match_lemma(headword)
      bump(lemma_id ? :matched_to_lemma : :no_lemma_match)

      summary = extract_summary(entry)

      meta = {
        entry_id: entry["id"],
        key: entry["key"],
        type: entry["type"],
        beta_orth: orth_beta
      }.compact

      {
        source: SOURCE,
        lemma_id: lemma_id,
        headword: headword,
        normalized: headword.unicode_normalize(:nfc),
        transliteration: nil,
        part_of_speech: extract_pos(entry),
        summary_gloss: summary,
        body_html: render_entry_html(entry),
        citations: [],  # LSJ citations are author/work refs (not OSIS); skip
        meta: meta,
        license_id: @license_id,
        import_run_id: @import_run.id,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    def match_lemma(headword)
      idx = @lemma_index
      idx[headword] ||
        idx[headword.unicode_normalize(:nfc)] ||
        idx[strip_diacritics(headword).downcase]
    end

    # Short summary for popover display. LSJ entries open with a
    # morphological-forms block (aorist, perfect, dialect variants…)
    # before getting to the actual definition. The definition itself
    # lives in `<tr>` (translation) elements — those carry the bilingual
    # gloss like "greet with affection", "love". Prefer the first <tr>;
    # only fall back to the first <sense> when no <tr> exists (rare —
    # mostly entries that LSJ only describes in Greek without translation).
    def extract_summary(entry)
      tr = entry.xpath(".//tr").first
      if tr
        text = collect_text(tr).gsub(/\s+/, " ").strip
        return truncate_summary(text) unless text.empty?
      end

      first_sense = entry.xpath(".//sense").first
      node = first_sense || entry
      text = collect_text(node).gsub(/\s+/, " ").strip
      return nil if text.empty?
      truncate_summary(text)
    end

    def truncate_summary(text)
      # Cut at first scripture-style citation marker — LSJ uses things
      # like "Pl. R. 358a", "Od. 23.214", "PBerol. 9859" which start
      # with a capital + period combo. Stop before the first one.
      if (idx = text.index(/[,;:.] +(?=[A-Z][a-zA-Z]*\.)/))
        text = text[0..idx].rstrip.sub(/[,;:]+\z/, "")
      end
      text = text[0..120].rstrip
      text << "…" if text.length >= 120
      text
    end

    # Recursive text collector that applies Beta Code conversion to
    # text inside Greek-marked elements. Tag-aware where Nokogiri's
    # `.text` is not.
    def collect_text(node, in_greek: false)
      out = +""
      node.children.each do |c|
        if c.text?
          out << (in_greek ? BetaCode.to_unicode(c.content) : c.content)
        elsif c.element?
          lang = c["lang"] || c["xml:lang"]
          child_in_greek = in_greek || (lang && GREEK_LANGS.include?(lang)) || %w[orth quote].include?(c.name)
          out << collect_text(c, in_greek: child_in_greek)
        end
      end
      out
    end

    def extract_pos(entry)
      entry.xpath(".//itype").first&.content&.strip
    end

    GREEK_LANGS = %w[greek grc].to_set.freeze

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
        when "orth"
          %(<span class="lex-orth" lang="el">#{render_greek_or_children(node)}</span>)
        when "foreign"
          lang = node["lang"] || node["xml:lang"]
          if lang && GREEK_LANGS.include?(lang)
            %(<span class="lex-foreign" lang="el">#{render_greek_text(node.text)}</span>)
          else
            %(<span class="lex-foreign"#{lang ? " lang=\"#{ERB::Util.h(lang)}\"" : ""}>#{render_children(node)}</span>)
          end
        when "sense"
          n = node["n"]
          level = node["level"]
          attrs = []
          attrs << %(data-n="#{ERB::Util.h(n)}") if n
          attrs << %(data-level="#{ERB::Util.h(level)}") if level
          %(<div class="lex-sense"#{attrs.empty? ? "" : " " + attrs.join(" ")}>#{render_children(node)}</div>)
        when "tr"
          %(<span class="lex-tr">#{render_children(node)}</span>)
        when "i"
          %(<i>#{render_children(node)}</i>)
        when "b"
          %(<b>#{render_children(node)}</b>)
        when "gen", "itype", "pos", "case", "number", "gender", "lbl", "usg"
          %(<span class="lex-#{node.name}">#{render_greek_or_children(node)}</span>)
        when "bibl", "cit", "ref"
          %(<span class="lex-bibl">#{render_children(node)}</span>)
        when "quote"
          %(<span class="lex-quote" lang="el">#{render_greek_text(node.text)}</span>)
        when "etym"
          %(<span class="lex-etym">#{render_children(node)}</span>)
        when "tns", "voice", "mood", "per", "dial"
          %(<span class="lex-#{node.name}">#{render_children(node)}</span>)
        else
          render_children(node)
        end
      else
        ""
      end
    end

    # Render a node's content as Greek if its lang attribute says so,
    # otherwise pass children through unchanged.
    def render_greek_or_children(node)
      lang = node["lang"] || node["xml:lang"]
      if lang && GREEK_LANGS.include?(lang)
        render_greek_text(node.text)
      else
        render_children(node)
      end
    end

    def render_greek_text(text)
      ERB::Util.h(BetaCode.to_unicode(text.to_s))
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
