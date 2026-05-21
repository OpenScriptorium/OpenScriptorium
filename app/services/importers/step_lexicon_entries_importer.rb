module Importers
  # Imports STEPBible's TBESG (Greek) and TBESH (Hebrew) brief lexicons
  # as `lexicon_entries` rows, source="STEPBible". Replaces the older
  # write-to-`lemmas.senses` path which produced inconsistent half-parsed
  # text that fought every regex cleanup pass.
  #
  # Source: https://github.com/STEPBible/STEPBible-Data/Lexicons
  # License: CC BY 4.0 (Tyndale House Cambridge / STEPBible.org)
  #
  # File format (tab-separated, one row per *extended* Strong's number):
  #   col 0: extended Strong's (G0001, G0001G, H0029K, …)
  #   col 1: relationship phrase ("G5216 = a Form of")
  #   col 2: target Strong's
  #   col 3: headword(s), comma-separated possibly multi-form
  #   col 4: transliteration
  #   col 5: part-of-speech tag
  #   col 6: short gloss
  #   col 7: structured body
  #
  # Greek bodies use BDAG-style "__N." / "__I." / "__(a)" markers for
  # nested senses. Hebrew bodies use "<br>1)" / "<br>2)" lists with a
  # "§" separator between biographical prose and lexical definition.
  # Both convert cleanly to a small set of tagged HTML elements
  # (lex-sense, lex-bibl, lex-def, lex-ref) which the existing lemma
  # show stylesheet already targets.
  class StepLexiconEntriesImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/stepbible")
    SOURCE = "STEPBible".freeze

    HEBREW_FAMILY = %w[he arc hbo].freeze
    GREEK_FAMILY  = %w[el el-koine grc].freeze

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://github.com/STEPBible/STEPBible-Data/tree/master/Lexicons"
    end

    def source_format
      "tsv"
    end

    def transactional?
      false
    end

    SOURCE_FILE_URLS = {
      "TBESH.txt" => "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/Lexicons/TBESH%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Hebrew%20-%20STEPBible.org%20CC%20BY.txt",
      "TBESG.txt" => "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/Lexicons/TBESG%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Greek%20-%20STEPBible.org%20CC%20BY.txt"
    }.freeze

    def perform
      download_source

      @license_id = License.find_by(spdx_id: "CC-BY-4.0")&.id

      Rails.logger.info "[StepLexiconEntriesImporter] wiping existing rows (source=#{SOURCE})"
      LexiconEntry.where(source: SOURCE).delete_all

      process_file(File.join(@dir, "TBESG.txt"), prefix: "G", langs: GREEK_FAMILY,  flavor: :greek)
      process_file(File.join(@dir, "TBESH.txt"), prefix: "H", langs: HEBREW_FAMILY, flavor: :hebrew)
    end

    def download_source
      require "open-uri"
      FileUtils.mkdir_p(@dir)
      SOURCE_FILE_URLS.each do |name, url|
        path = File.join(@dir, name)
        next if File.exist?(path)
        Rails.logger.info "[StepLexiconEntriesImporter] downloading #{name}"
        File.binwrite(path, URI.open(url).read)
        bump(:source_downloaded)
      end
    end

    private

    def process_file(path, prefix:, langs:, flavor:)
      headword_lemma_cache = {}
      batch = []
      n = 0
      File.foreach(path) do |line|
        cols = line.split("\t")
        next if cols.size < 8
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)

        base = ext.match(/\A([HG])0*(\d+)/) and base = "#{base[1]}#{base[2].to_i}"
        next unless base

        rel       = cols[1].to_s
        target    = cols[2].to_s.strip
        hw_field  = cols[3].to_s
        translit  = cols[4].to_s.strip
        pos       = cols[5].to_s.strip
        gloss     = cols[6].to_s.strip
        body_raw  = cols[7].to_s
        next if body_raw.strip.empty?

        # Find a matching lemma — try each comma-separated variant in
        # the headword field. NFC-normalize before lookup since some
        # importers wrote NFC, others NFD (Hebrew niqqud orderings).
        headwords = hw_field.split(",").map { |h| h.strip.unicode_normalize(:nfc) }.reject(&:empty?)
        lemma_id = nil
        primary_hw = nil
        headwords.each do |hw|
          key = [langs, hw]
          headword_lemma_cache[key] = Lemma.where(language: langs, lemma: hw).pick(:id) unless headword_lemma_cache.key?(key)
          if (id = headword_lemma_cache[key])
            lemma_id ||= id
            primary_hw ||= hw
          end
        end
        primary_hw ||= headwords.first || base

        body_html = render_body(body_raw, flavor: flavor)
        next if body_html.blank?

        batch << {
          source: SOURCE,
          lemma_id: lemma_id,
          headword: primary_hw,
          normalized: primary_hw,
          transliteration: translit.presence,
          part_of_speech: pos.presence,
          summary_gloss: gloss.presence,
          body_html: body_html,
          citations: extract_refs(body_raw),
          meta: {
            strong:        base,
            ext_strong:    ext,
            relationship:  rel.presence,
            target_strong: target.presence
          }.compact,
          license_id: @license_id,
          import_run_id: @import_run.id,
          created_at: Time.current,
          updated_at: Time.current
        }

        n += 1
        if batch.size >= 1000
          LexiconEntry.insert_all(batch)
          batch.clear
        end
        if n % 5000 == 0
          $stdout.puts "[StepLexiconEntriesImporter] #{prefix} #{n} rows processed"
          $stdout.flush
        end
      end
      LexiconEntry.insert_all(batch) if batch.any?
      bump(:"#{flavor}_entries", n)
    end

    # ------------------------------------------------------------
    # Body rendering
    #
    # Both flavors emit the same minimal HTML vocabulary:
    #   <div class="lex-head">...</div>     headword/grammar/inline-def paragraphs
    #   <div class="lex-headline">...</div> Hebrew "§ HEADWORD = "meaning"" line
    #   <div class="lex-prose">...</div>    Hebrew biographical prose before §
    #   <div class="lex-sense" data-level data-marker>...</div> numbered/lettered sense
    #   <div class="lex-related">...</div>  trailing "Aramaic equivalent: ..." note
    #
    # The CSS already styles lex-sense by data-level for indentation.
    # ------------------------------------------------------------

    REF_PATTERN = /<ref=['"]([^'"]+)['"]>([^<]*)<\/ref>/.freeze

    # TBESG (Greek) BDAG-style inline markers. Listed in level order:
    # I. = 1, 1. = 2, (a) = 3, (1) = 4, α) = 5, (α) = 6.
    GREEK_MARKER_RE = /__(?:([IVX]+)\.|(\d+)\.|\(([a-z]+)\)|\(([IVX]+)\)|(\(with\))|([αβγδεζηθικλμνξοπρστυφχψω])\)|\(([αβγδεζηθικλμνξοπρστυφχψω])\))/.freeze

    # TBESH (Hebrew) numbered list markers. Levels are the count of
    # alternating digit/letter segments: 1 = L1, 1a = L2, 1a1 = L3,
    # 1a1a = L4, 1a1a1 = L5. The marker must appear at the start of a
    # <br>-delimited segment (or at the start of the body).
    HEBREW_MARKER_RE = /\A(\d+(?:[a-z]\d*)*)\)\s*/.freeze

    # Trailer recognizers — non-numbered content that appears AFTER the
    # last sense and should render as a separate related-info block.
    HEBREW_TRAILER_RE = /\A(?:Aramaic\b|Combined with\b|Compare\b|Same as\b|Used\b|Name of\b|Plural of\b)/.freeze

    def extract_refs(body_raw)
      body_raw.scan(REF_PATTERN).map(&:first).uniq
    end

    def render_body(raw, flavor:)
      cleaned = sanitize_inline(raw)
      return "" if cleaned.empty?
      case flavor
      when :greek  then render_greek_body(cleaned)
      when :hebrew then render_hebrew_body(cleaned)
      end
    end

    # Convert <ref='Foo.1.1'>X</ref> → <a class="lex-ref" data-ref>X</a>;
    # collapse <BR/> to <br>; convert <b>/<i> to <strong>/<em>;
    # strip trailing "(AS)" attribution (Abbott-Smith); decode entities.
    def sanitize_inline(raw)
      s = raw.dup
      s.gsub!(/&nbsp;/i, " ")
      s.gsub!(REF_PATTERN) do
        ref  = ::Regexp.last_match(1)
        text = ::Regexp.last_match(2)
        %(<a class="lex-ref" data-ref="#{ERB::Util.h(ref)}">#{ERB::Util.h(text)}</a>)
      end
      s.gsub!(/<\s*BR\s*\/?>/i, "<br>")
      s.gsub!(/<\s*\/?b\s*>/i)  { |t| t.include?("/") ? "</strong>" : "<strong>" }
      s.gsub!(/<\s*\/?i\s*>/i)  { |t| t.include?("/") ? "</em>"     : "<em>" }
      # Drop unknown wrapper tags (date/author/variant) but keep their text.
      s.gsub!(/<\s*\/?(date|author|variant)\s*>/i, "")
      # Drop trailing attribution "(AS)"/"(MT)" etc.
      s.sub!(/\s*\((?:AS|MT|MM|ML)\)\s*\z/, "")
      s.strip
    end

    # ------------------------------------------------------------
    # Greek
    # ------------------------------------------------------------
    #
    # Greek BDAG bodies look like:
    #   <strong>LEMMA</strong>, grammar, <br> [in LXX for ...], <br>
    #   <strong>english-meaning</strong>: definition prose with refs.
    #   __1. first sense.  __(a) sub-sense.  __2. second sense.
    #
    # The __markers split the body into (head, sense*). The head splits
    # further on <br> into prose paragraphs.

    def render_greek_body(cleaned)
      head, senses = split_greek(cleaned)
      out = +render_paragraphs(head, "lex-head")
      senses.each do |level, marker, content|
        out << render_sense(level, marker, content)
      end
      out
    end

    # Split a sanitized Greek body into [head, [[level, marker, content], ...]].
    # Walks the body forwards, finding __marker positions.
    def split_greek(s)
      positions = []
      s.to_enum(:scan, GREEK_MARKER_RE).each do
        m = Regexp.last_match
        marker, level = greek_level_for(m)
        positions << { start: m.begin(0), body_start: m.end(0), marker: marker, level: level }
      end
      return [s, []] if positions.empty?

      head = s[0...positions.first[:start]]
      senses = positions.each_with_index.map do |p, i|
        stop = positions[i + 1] ? positions[i + 1][:start] : s.length
        content = s[p[:body_start]...stop].to_s
        # Greek senses often have a leading "<br>" or " " from the source.
        content = content.sub(/\A(?:<br>|\s|\.)+/, "").strip
        [p[:level], p[:marker], content]
      end
      [head, senses]
    end

    def greek_level_for(m)
      return [m[1], 1] if m[1]                     # I. II. III.
      return [m[2], 2] if m[2]                     # 1. 2. 3.
      return [m[3], 3] if m[3]                     # (a) (b) (with-letter)
      return [m[4], 4] if m[4]                     # (I) (II)
      return ["with", 3] if m[5]                   # (with)
      return [m[6], 5] if m[6]                     # α) β)
      return [m[7], 6] if m[7]                     # (α) (β)
      [nil, nil]
    end

    # ------------------------------------------------------------
    # Hebrew
    # ------------------------------------------------------------
    #
    # Hebrew bodies are <br>-delimited. Each segment is classified:
    #   - "§ ..." — section break: prose-context above ends, lexical entry begins.
    #   - matches HEBREW_MARKER_RE — numbered sense at the marker's depth.
    #   - HEBREW_TRAILER_RE-prefixed segment AFTER any senses — related note.
    #   - anything else — prose paragraph (head, prose, or definition).

    def render_hebrew_body(cleaned)
      segments = cleaned.split(/<br>/).map(&:strip).reject(&:empty?)
      return "" if segments.empty?

      out = +""
      head_buf = []         # buffered prose paragraphs awaiting flush
      saw_section = false   # have we passed a "§" divider yet?
      saw_sense   = false   # have we emitted any lex-sense yet?

      flush_head = lambda do
        head_buf.each do |seg|
          klass = saw_sense    ? "lex-related" :
                  saw_section  ? "lex-prose"   :
                                 "lex-head"
          out << %(<div class="#{klass}">#{seg}</div>)
        end
        head_buf.clear
      end

      segments.each do |seg|
        # Section break: text starting with "§" begins the dictionary
        # portion of a biographical entry. The remainder of the segment
        # is the headline ('Abagtha = "God-given"').
        if seg.start_with?("§")
          flush_head.call
          saw_section = true
          headline = seg.sub(/\A§\s*/, "").strip
          out << %(<div class="lex-headline">#{headline}</div>) unless headline.empty?
          next
        end

        # Numbered sense.
        if (m = HEBREW_MARKER_RE.match(seg))
          flush_head.call
          marker  = m[1]
          level   = marker.scan(/\d+|[a-z]+/).size
          content = seg.sub(HEBREW_MARKER_RE, "").strip
          out << render_sense(level, marker, content)
          saw_sense = true
          next
        end

        # Trailer note after at least one sense.
        if saw_sense && seg.match?(HEBREW_TRAILER_RE)
          flush_head.call
          out << %(<div class="lex-related">#{seg}</div>)
          next
        end

        # Default: buffered prose paragraph. Buffering lets us pick the
        # right CSS class based on what's around it.
        head_buf << seg
      end

      flush_head.call
      out
    end

    # ------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------

    def render_paragraphs(s, css_class)
      chunks = s.to_s.split(/<br>/).map(&:strip).reject(&:empty?)
      chunks.map { |c| %(<div class="#{css_class}">#{c}</div>) }.join
    end

    def render_sense(level, marker, content)
      # Strip trailing <br> that often dangles before the next marker.
      content = content.sub(/<br>\s*\z/, "").strip
      %(<div class="lex-sense" data-level="#{level}" data-marker="#{ERB::Util.h(marker)}">#{content}</div>)
    end
  end
end
