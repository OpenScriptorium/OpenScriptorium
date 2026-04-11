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
end
