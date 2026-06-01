# Renders morph codes as prose. Three input formats are recognized:
#
#   - Nestle / SBLGNT dash-separated     ("V-AAI-3S" → "Verb, Aorist Active Indicative 3rd Singular")
#   - CNTR positional                    ("V:PAI3S.." → "Verb, Present Active Indicative 3rd Person Singular")
#   - lxx-morph human-readable lowercase ("verb aor ind mid/pass 3rd sg" → "Verb, Aorist Indicative Middle/Passive 3rd Singular")
#
# BSB-table Words carry a notes["parsing_long"] field already; this
# class fills in for the works that don't (RP, CNTR-SR, Rahlfs LXX).
require "set"

class MorphCodeHumanizer
  POS_NAMES = {
    "N"  => "Noun",
    "V"  => "Verb",
    "A"  => "Adjective",
    "D"  => "Adverb",
    "C"  => "Conjunction",
    "P"  => "Preposition",
    "T"  => "Article",          # SBLGNT uses T for the article (τοῦ etc.)
    "R"  => "Pronoun",
    "I"  => "Interrogative pronoun",
    "Q"  => "Particle",
    "X"  => "Particle",
  }.freeze

  TENSE = { "P" => "Present",     "I" => "Imperfect", "F" => "Future",
            "A" => "Aorist",      "R" => "Perfect",   "L" => "Pluperfect",
            "X" => "" }.freeze
  VOICE = { "A" => "Active",      "M" => "Middle",    "P" => "Passive",
            "E" => "Middle/Passive", "D" => "Middle deponent",
            "O" => "Middle/Passive deponent", "N" => "Middle/Passive deponent" }.freeze
  MOOD  = { "I" => "Indicative",  "S" => "Subjunctive", "O" => "Optative",
            "M" => "Imperative",  "N" => "Infinitive",  "P" => "Participle" }.freeze
  CASE  = { "N" => "Nominative",  "G" => "Genitive",    "D" => "Dative",
            "A" => "Accusative",  "V" => "Vocative" }.freeze
  GENDER = { "M" => "Masculine", "F" => "Feminine", "N" => "Neuter" }.freeze
  NUMBER = { "S" => "Singular", "P" => "Plural", "D" => "Dual" }.freeze
  PERSON = { "1" => "1st", "2" => "2nd", "3" => "3rd" }.freeze

  # lxx-morph format vocabularies. Multi-word POS ("proper noun") is
  # detected before single-token POS in #humanize_lxx_morph.
  LXX_POS = {
    "verb"        => "Verb",
    "noun"        => "Noun",
    "adjective"   => "Adjective",
    "article"     => "Article",
    "pronoun"     => "Pronoun",
    "participle"  => "Participle",
    "preposition" => "Preposition",
    "conjunction" => "Conjunction",
    "particle"    => "Particle",
    "adverb"      => "Adverb",
    "numeral"     => "Numeral",
    "interjection" => "Interjection",
  }.freeze

  LXX_TOKEN = {
    # Tense
    "pres" => "Present", "impf" => "Imperfect", "aor" => "Aorist",
    "fut"  => "Future",  "perf" => "Perfect",   "plup" => "Pluperfect",
    # Voice
    "act" => "Active", "mid" => "Middle", "pass" => "Passive",
    # Mood
    "ind" => "Indicative", "subj" => "Subjunctive", "opt" => "Optative",
    "imperat" => "Imperative", "imp" => "Imperative",
    "inf" => "Infinitive", "ptc" => "Participle",
    # Person
    "1st" => "1st", "2nd" => "2nd", "3rd" => "3rd",
    # Number
    "sg" => "Singular", "pl" => "Plural", "dual" => "Dual",
    # Gender
    "masc" => "Masculine", "fem" => "Feminine", "neut" => "Neuter",
    # Case
    "nom" => "Nominative", "voc" => "Vocative", "acc" => "Accusative",
    "gen" => "Genitive",   "dat" => "Dative",
    # Degree / extras
    "comp" => "Comparative", "sup" => "Superlative",
    "adverbial" => "Adverbial",
  }.freeze

  # Entry point. Returns prose, or the raw code if we can't parse.
  def self.humanize(code)
    return nil if code.blank?

    # Nestle / SBLGNT style: dash-separated. "V-AAI-3S", "N-NSF", "A-DPM".
    if code.include?("-")
      parts = code.split("-").map(&:strip)
      return humanize_dashed(parts) || code
    end

    # CNTR positional style: 8 chars, e.g. "N:....NFS" or "V:PAI3S..".
    if code =~ /\A([A-Z]):([A-Z0-9.]+)\z/
      return humanize_cntr($1, $2) || code
    end

    # lxx-morph human-readable: lowercase, space-separated, first
    # token is a known POS word ("verb aor ind mid/pass 3rd sg").
    if code =~ /\A[a-z]/ && code.include?(" ") || LXX_POS.key?(code) || code == "proper noun"
      result = humanize_lxx_morph(code)
      return result if result
    end

    code
  end

  def self.humanize_dashed(parts)
    return nil if parts.empty?
    pos_letter = parts[0]
    pos_name = POS_NAMES[pos_letter] or return nil

    rest = parts[1..]
    return pos_name if rest.empty?

    # Verbs follow "TVM[-PN]" — Tense, Voice, Mood, then Person+Number.
    if pos_letter == "V" && rest.first&.length == 3
      tvm = rest.first
      pn  = rest[1]
      pieces = [TENSE[tvm[0]], VOICE[tvm[1]], MOOD[tvm[2]]].compact.reject(&:empty?)
      if pn && pn =~ /\A([1-3])([SPD])\z/
        pieces << "#{PERSON[$1]} #{NUMBER[$2]}"
      end
      return "Verb, #{pieces.join(' ')}"
    end

    # Nouns/Adjectives/Articles: 3-letter parsing block. Two competing
    # conventions across our corpus:
    #   RP (SBLGNT)  : Case-Number-Gender   → "NSF" = NomSgFem
    #   Nestle 1904  : Case-Gender-Number   → "NFS" = NomFemSg
    # Try both orderings.
    if rest.first&.length == 3
      a, b, c = rest.first.chars
      if CASE[a] && NUMBER[b] && GENDER[c]
        return "#{pos_name}, #{CASE[a]} #{NUMBER[b]} #{GENDER[c]}"
      elsif CASE[a] && GENDER[b] && NUMBER[c]
        return "#{pos_name}, #{CASE[a]} #{GENDER[b]} #{NUMBER[c]}"
      end
    end

    pos_name
  end

  # Parse the lxx-morph human-readable format. Returns nil if the
  # leading POS isn't recognized so the caller can fall back to the
  # raw code.
  def self.humanize_lxx_morph(code)
    tokens = code.split(/\s+/)
    return nil if tokens.empty?

    # "proper noun" — two-word POS, peel both off.
    if tokens[0] == "proper" && tokens[1] == "noun"
      pos_name = "Proper Noun"
      rest = tokens[2..]
    else
      pos_name = LXX_POS[tokens[0]]
      return nil unless pos_name
      rest = tokens[1..]
    end

    return pos_name if rest.empty?

    pieces = rest.map { |t| lxx_token_to_prose(t) }.compact
    pieces.empty? ? pos_name : "#{pos_name}, #{pieces.join(' ')}"
  end

  # Translate a single parsing token. Slash-sets ("masc/neut", "nom/voc/acc")
  # are expanded by mapping each segment and rejoining with slashes — only
  # if every segment maps. Unknown tokens return nil.
  def self.lxx_token_to_prose(token)
    return LXX_TOKEN[token] if LXX_TOKEN.key?(token)
    if token.include?("/")
      parts = token.split("/").map { |p| LXX_TOKEN[p] }
      return parts.join("/") if parts.none?(&:nil?)
    end
    nil
  end

  def self.humanize_cntr(pos_letter, parsing)
    pos_name = POS_NAMES[pos_letter] or return nil
    # CNTR positions vary by POS — verbs are TVMPN (tense voice mood
    # person number) while nouns are ....CNG or ....CGN. Look up each
    # non-dot character against the appropriate category for its slot,
    # but accept lookups in either order for the slots that vary.
    chars = parsing.chars
    pieces = []
    pieces << TENSE[chars[0]]  if chars[0] && chars[0] != "." && TENSE[chars[0]]
    pieces << VOICE[chars[1]]  if chars[1] && chars[1] != "." && VOICE[chars[1]]
    pieces << MOOD[chars[2]]   if chars[2] && chars[2] != "." && MOOD[chars[2]]
    pieces << "#{PERSON[chars[3]]} person" if chars[3] && PERSON[chars[3]]

    # Slots 4-7 carry case/number/gender in varying order across POS.
    # Try each remaining non-dot character against case, number, gender.
    seen = Set.new
    (4..7).each do |i|
      c = chars[i]
      next if c.nil? || c == "."
      if CASE[c] && !seen.include?(:case)
        pieces << CASE[c]; seen << :case
      elsif NUMBER[c] && !seen.include?(:number)
        pieces << NUMBER[c]; seen << :number
      elsif GENDER[c] && !seen.include?(:gender)
        pieces << GENDER[c]; seen << :gender
      end
    end
    pieces = pieces.compact.reject(&:empty?)
    pieces.empty? ? pos_name : "#{pos_name}, #{pieces.join(' ')}"
  end
end
