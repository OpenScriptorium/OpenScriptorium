module ReaderHelper
  # Language metadata for the reader UI. Maps a Work's BCP-47 language
  # tag to the right CSS classes (font + size + line height) and
  # HTML attributes (lang, dir).
  LANGUAGE_PRESENTATION = {
    "he"       => { font: "font-hebrew", size: "text-3xl", leading: "leading-loose", dir: "rtl" },
    "arc"      => { font: "font-hebrew", size: "text-3xl", leading: "leading-loose", dir: "rtl" },
    "el-koine" => { font: "font-greek",  size: "text-2xl", leading: "leading-loose", dir: "ltr" },
    "el"       => { font: "font-greek",  size: "text-2xl", leading: "leading-loose", dir: "ltr" },
    "la"       => { font: "font-serif",  size: "text-xl",  leading: "leading-relaxed", dir: "ltr" },
  }.freeze

  # Returns a Tailwind class string for rendering scripture in the
  # given Work's language. Defaults to the existing `.scripture` class
  # for English and other languages.
  def scripture_classes_for(work)
    p = LANGUAGE_PRESENTATION[work.language]
    return "scripture" unless p
    "#{p[:font]} #{p[:size]} #{p[:leading]} text-[--color-ink]"
  end

  # HTML attributes (lang + dir) appropriate to the work's language.
  def scripture_html_attrs(work)
    p = LANGUAGE_PRESENTATION[work.language] || {}
    {
      lang: work.language,
      dir:  p[:dir] || "ltr"
    }
  end

  # Returns true when the work uses an RTL script.
  def rtl_work?(work)
    LANGUAGE_PRESENTATION.dig(work.language, :dir) == "rtl"
  end
end
