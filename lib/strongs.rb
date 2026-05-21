module Strongs
  # Strong's number normalization.
  #
  # The corpus stores Strong's in inconsistent shapes inherited from the
  # source datasets:
  #
  #   - BSB / WLC / Nestle1904 / RP write bare numbers ("26", "7225").
  #   - KJV / CNTR-SR write H/G-prefixed ("G26", "H7225").
  #   - Patriarchal-1904 writes leading-zero variants ("G0002").
  #   - KJV's per-word importer occasionally writes multi-number strings
  #     ("G1012,G5087") for English words that translate two Greek words.
  #
  # Result on the lemma page meta: rendering "Strong's 3370, G337,
  # G3370, G33700" all for the same lemma — every storage variant
  # appears as if it were a distinct Strong's. This module collapses
  # them to one canonical "G####" / "H####" form per lemma.
  #
  # Strategy is display-time normalization rather than rewriting the
  # words table: lossy storage variants are recoverable from context
  # (we know the lemma's language), and a backfill migration on a
  # 1.95M-row table is more risk than the display fix is worth.

  PREFIX_FOR_LANG = {
    "he"       => "H",
    "arc"      => "H",
    "el"       => "G",
    "el-koine" => "G"
  }.freeze

  # Normalize a single Strong's-number string to canonical "G####" or
  # "H####". Returns nil for blank, multi-number, or bare numbers when
  # no language is given to disambiguate Hebrew vs Greek.
  def self.normalize(raw, language: nil)
    s = raw.to_s.strip
    return nil if s.empty?
    return nil if s.include?(",")

    m = s.match(/\A([HGhg])?0*(\d+)\z/)
    return nil unless m

    prefix = m[1]&.upcase || PREFIX_FOR_LANG[language]
    return nil unless prefix

    num = m[2].to_i
    return nil if num <= 0 || num > 99999
    "#{prefix}#{num}"
  end

  # Reduce an array of raw strongs_number strings to a deduped, sorted,
  # canonical list. Drops anything `normalize` rejects.
  def self.normalize_set(raws, language: nil)
    raws
      .filter_map { |r| normalize(r, language: language) }
      .uniq
      .sort_by { |s| [s[0], s[1..].to_i] }
  end

  # Like normalize_set, but additionally collapses trailing-zero noise:
  # if "G35880" appears alongside "G3588" in the set, "G35880" is treated
  # as a corrupted suffix of "G3588" and dropped. This catches the
  # trailing-zero importer bug ("G33700" for "G3370", "G35880" for
  # "G3588") without blocking legitimate close-numbered homographs
  # (H3587 alongside H3588 — different lexicon entries that share a
  # surface form, both kept).
  #
  # Genuinely-wrong importer data (e.g. KJV writing "G337" instead of
  # "G3370" for 21 words of Μῆδος) is *not* something this can catch —
  # G337 is a real, different Strong's number. That's an importer bug
  # that needs a real fix.
  def self.normalize_set_with_counts(raws_to_counts, language: nil)
    canonical = Hash.new(0)
    raws_to_counts.each do |raw, n|
      canon = normalize(raw, language: language)
      next unless canon
      canonical[canon] += n
    end

    # Two collapse cases share one rule: if a Strong's S has a shorter
    # form S[0..-2] also present in the same set AND that shorter form
    # has more occurrences, treat S as a variant and drop it.
    #
    # Catches:
    #   • Trailing-zero noise: "G35880" → "G3588" (importer bug data).
    #   • CNTR Enhanced Strong's homonym variants: G250, G251, G252,
    #     ..., G259 are all CNTR's per-variant-of-base ESNs for the
    #     same lemma. After consolidation, a single canonical lemma
    #     can carry the base ("G25") plus a fan of variant ESNs;
    #     they should display as one Strong's number, not ten.
    #
    # The "shorter has more" guard prevents over-collapsing legitimately
    # distinct numbers (e.g. G337 ἀναιρέω vs G3370 Μῆδος — there G3370
    # is the more-common form, so it stays distinct).
    canonical
      .reject { |s, n|
        bare = s[1..].to_s
        next false if bare.length < 2
        short = "#{s[0]}#{bare[0..-2]}"
        canonical.key?(short) && canonical[short] > n
      }
      .keys
      .sort_by { |s| [s[0], s[1..].to_i] }
  end
end
