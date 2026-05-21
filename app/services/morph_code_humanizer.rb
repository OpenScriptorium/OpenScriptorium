# Renders Nestle/SBLGNT and CNTR-style morph codes as prose ("V-AAI-3S"
# → "Verb, Aorist Active Indicative, 3rd Singular"). BSB-table Words
# carry a notes["parsing_long"] field already; this is for the works
# that don't (RP, CNTR-SR).
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
