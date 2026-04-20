module Search
  class CitationParser
    # Parses a citation string like "Gen 1:1" or "1 Sam 3:16" into structured
    # data that can resolve to a canonical_ref. Returns nil if unparseable.

    ParsedCitation = Data.define(:abbreviation, :book_key, :canonical_work_id,
                                 :chapter, :verse, :end_verse)

    def self.parse(query)
      new.parse(query)
    end

    def parse(query)
      q = query.to_s.strip
      return nil if q.blank?

      match = q.match(citation_pattern)
      return nil unless match

      book_part = match[:book].strip
      chapter   = match[:chapter]&.to_i
      verse     = match[:verse]&.to_i
      end_verse = match[:end_verse]&.to_i

      canonical_work = resolve_book(book_part)
      return nil unless canonical_work

      ParsedCitation.new(
        abbreviation: book_part,
        book_key: canonical_work.book_key,
        canonical_work_id: canonical_work.id,
        chapter: chapter,
        verse: verse,
        end_verse: end_verse
      )
    end

    # Resolve a parsed citation to canonical_refs for redirect.
    # Returns { work_slug:, book_slug:, chapter:, verse:, end_verse: } or nil.
    def self.resolve(query)
      parsed = parse(query)
      return nil unless parsed

      # Find a work that has work_units for this canonical_work.
      # Multiple canonical_works may share the same abbreviation (e.g.,
      # "Genesis" and "Genesis (MT)"), so try the parsed one first,
      # then fall back to siblings with the same abbreviation.
      candidate_ids = CanonicalWork
        .where(sbl_abbreviation: CanonicalWork.find_by(id: parsed.canonical_work_id)&.sbl_abbreviation)
        .pluck(:id)

      # Prefer English scripture translations for citation redirects.
      # BSB/KJV before Brenton/LXX, English before other languages.
      work_ids = WorkUnit.joins(:canonical_ref)
                         .where(canonical_refs: { canonical_work_id: candidate_ids })
                         .distinct
                         .pluck(:work_id)
      work = Work.where(id: work_ids)
                 .order(Arel.sql("CASE work_type
                    WHEN 'scripture_translation' THEN 0
                    WHEN 'scripture_original' THEN 1
                    ELSE 2 END,
                  CASE WHEN language = 'en' THEN 0 ELSE 1 END,
                  CASE slug WHEN 'bsb' THEN 0 WHEN 'kjv' THEN 1 WHEN 'webbe' THEN 2 ELSE 3 END,
                  slug"))
                 .first
      return nil unless work

      # Resolve the book_key from the canonical_work that actually matched
      actual_cw_id = WorkUnit.joins(:canonical_ref)
                             .where(work: work, canonical_refs: { canonical_work_id: candidate_ids })
                             .pick("canonical_refs.canonical_work_id")
      actual_cw = CanonicalWork.find(actual_cw_id)

      {
        work_slug: work.slug,
        book_slug: actual_cw.book_key,
        chapter: parsed.chapter,
        verse: parsed.verse,
        end_verse: parsed.end_verse
      }
    end

    private

    def citation_pattern
      /\A(?<book>(?:\d\s+)?[A-Za-z][A-Za-z.\s]*?)\s+(?<chapter>\d+)(?::(?<verse>\d+)(?:-(?<end_verse>\d+))?)?\z/
    end

    def resolve_book(book_part)
      normalized = book_part.downcase.gsub(/[.\s]+/, " ").strip

      # Try exact SBL abbreviation match first
      cw = abbreviation_map[normalized]
      return cw if cw

      # Try full title match
      cw = title_map[normalized]
      return cw if cw

      # Try prefix match on SBL abbreviation (e.g., "gen" matches "Gen")
      abbreviation_map.each do |abbr, work|
        return work if abbr.start_with?(normalized)
      end

      nil
    end

    def abbreviation_map
      @abbreviation_map ||= build_abbreviation_map
    end

    def title_map
      @title_map ||= build_title_map
    end

    def build_abbreviation_map
      map = {}
      CanonicalWork.pluck(:id, :sbl_abbreviation, :book_key, :title).each do |id, abbr, bk, title|
        next if abbr.blank?
        key = abbr.downcase.gsub(/[.\s]+/, " ").strip
        # Store the full record data we need
        map[key] ||= CanonicalWork.find(id)
      end
      map
    end

    def build_title_map
      map = {}
      CanonicalWork.find_each do |cw|
        key = cw.title.downcase.gsub(/[.\s]+/, " ").strip
        map[key] ||= cw
        # Also store without parenthetical scheme tags
        display = cw.display_title.downcase.gsub(/[.\s]+/, " ").strip
        map[display] ||= cw if display != key
      end
      map
    end
  end
end
