# Beta Code → polytonic Greek (Unicode NFC) converter.
#
# Beta Code is the ASCII transliteration used by TLG and Perseus to
# encode polytonic Greek. We need it to decode LSJ entry keys like
# "kri/nw" → κρίνω and "le/gw2" → λέγω (with homonym suffix 2).
#
# Only the subset relevant to LSJ keys is implemented:
#
#   letters   a b g d e z h q i k l m n c o p r s t u f x y w v
#             (v = digamma)
#   capital   * prefix
#   diacritics ( rough ) smooth / acute \ grave = circumflex
#             | iota-subscript + diaeresis
#   length    _ macron ^ breve  (recorded position-wise, not encoded
#             in the output — they aren't combining marks in Unicode)
#   misc      - compound separator (stripped)
#             ' apostrophe / elision (passed through)
#             trailing digits → homonym number (extracted separately)
module BetaCode
  LETTERS = {
    "a" => "α", "b" => "β", "g" => "γ", "d" => "δ", "e" => "ε",
    "z" => "ζ", "h" => "η", "q" => "θ", "i" => "ι", "k" => "κ",
    "l" => "λ", "m" => "μ", "n" => "ν", "c" => "ξ", "o" => "ο",
    "p" => "π", "r" => "ρ", "s" => "σ", "t" => "τ", "u" => "υ",
    "f" => "φ", "x" => "χ", "y" => "ψ", "w" => "ω", "v" => "ϝ"
  }.freeze

  COMBINING = {
    "(" => "̔",  # rough breathing
    ")" => "̓",  # smooth breathing
    "/" => "́",  # acute
    "\\" => "̀", # grave
    "=" => "͂",  # circumflex (perispomeni)
    "|" => "ͅ",  # iota subscript (ypogegrammeni)
    "+" => "̈"   # diaeresis
  }.freeze

  DIACRITIC_CHARS = "()/\\=|+_^".chars.to_set.freeze

  # Decode a Beta Code string to NFC polytonic Greek.
  # Returns [unicode_string, homonym_n] — homonym_n is the trailing
  # integer suffix if present, else nil. So "le/gw2" → ["λέγω", 2].
  def self.decode(beta)
    return ["", nil] if beta.nil? || beta.empty?

    # Pull trailing homonym digits off first.
    homonym = nil
    if (m = beta.match(/\A(.*?)(\d+)\z/))
      beta = m[1]
      homonym = m[2].to_i
    end

    chars = beta.chars
    out = +""
    i = 0
    capitalize = false
    while i < chars.length
      c = chars[i]
      if c == "*"
        capitalize = true
        i += 1
        next
      end

      if c == "-"
        # Compound separator — strip silently.
        i += 1
        next
      end

      if (letter = LETTERS[c])
        # Collect diacritics following this letter.
        marks = +""
        j = i + 1
        while j < chars.length && DIACRITIC_CHARS.include?(chars[j])
          mark = COMBINING[chars[j]]
          marks << mark if mark  # _ and ^ ignored — no NFC representation
          j += 1
        end
        composed = (letter + marks).unicode_normalize(:nfc)
        composed = composed.upcase if capitalize
        out << composed
        capitalize = false
        i = j
      else
        # Unknown / punctuation — pass through.
        out << c
        capitalize = false
        i += 1
      end
    end

    [final_sigma(out.unicode_normalize(:nfc)), homonym]
  end

  # Word-final σ → ς. Word boundaries are start/end and whitespace.
  def self.final_sigma(s)
    s.gsub(/σ(?=\s|\z)/, "ς")
  end

  # Convenience alias: caller only wants the decoded Greek string,
  # not the homonym suffix. Used by the legacy LsjImporter.
  def self.to_unicode(beta)
    decode(beta).first
  end
end
