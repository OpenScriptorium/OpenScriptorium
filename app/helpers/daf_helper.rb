module DafHelper
  # Split a commentary body into [dibur_hamatchil, body].
  # The Wikisource Talmud text uses " – " (space-en-dash-space) to
  # separate the catchword from the commentary. If no separator is
  # found, returns [nil, full_text].
  def split_commentary(text)
    idx = text.index(" – ")
    if idx
      [text[0...idx], text[(idx + 3)..]]
    else
      [nil, text]
    end
  end

  def daf_label(daf_number, amud_int)
    "#{daf_number}#{amud_int == 1 ? 'a' : 'b'}"
  end

  def daf_nav_path(work_slug, book_slug, daf_number, amud_int)
    daf_path(work_slug, book_slug, daf_label(daf_number, amud_int))
  end

  # "2a" → "דף ב ע״א"
  def daf_label_hebrew(daf_number, amud_int)
    amud = amud_int == 1 ? "ע״א" : "ע״ב"
    "דף #{to_gematria(daf_number)} #{amud}"
  end

  GEMATRIA_ONES = ["", "א", "ב", "ג", "ד", "ה", "ו", "ז", "ח", "ט"].freeze
  GEMATRIA_TENS = ["", "י", "כ", "ל", "מ", "נ", "ס", "ע", "פ", "צ"].freeze
  GEMATRIA_HUNDREDS = ["", "ק", "ר", "ש", "ת"].freeze

  def to_gematria(n)
    return n.to_s if n <= 0 || n > 999
    h = GEMATRIA_HUNDREDS[[n / 100, 4].min]
    r = n % 100
    if r == 15 then t, o = "ט", "ו"
    elsif r == 16 then t, o = "ט", "ז"
    else t, o = GEMATRIA_TENS[r / 10], GEMATRIA_ONES[r % 10]
    end
    letters = "#{h}#{t}#{o}"
    if letters.length == 1
      "#{letters}׳"
    else
      "#{letters[0..-2]}״#{letters[-1]}"
    end
  end
end
