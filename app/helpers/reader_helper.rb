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
    "#{p[:font]} #{p[:size]} #{p[:leading]} text-[var(--color-ink)]"
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

  # Companion priority for the contextual "Read in parallel" links.
  # The current work is always inserted first as the primary row anchor;
  # we then add ONE companion (default = 2 columns total) — the user can
  # add more from the picker on the parallel page itself.
  PARALLEL_COMPANION_PRIORITY = %w[bsb wlc nestle1904 rahlfs-lxx brenton-lxx rp].freeze

  # Build a comma-separated `works=` parameter for the parallel reader,
  # seeded with the current work as primary plus the highest-priority
  # companion that isn't the current work. Returns 2 work slugs by
  # default; the parallel page's picker form lets the user expand from
  # there.
  def parallel_works_param(current_work)
    available  = Work.where(slug: PARALLEL_COMPANION_PRIORITY).pluck(:slug)
    companions = (PARALLEL_COMPANION_PRIORITY & available) - [current_work.slug]
    ([current_work.slug] + companions.first(1)).join(",")
  end

  # ==========================================================
  # Marginal note rendering
  # ==========================================================

  # Renders the verse body with each note's anchor phrase wrapped in
  # a `<span class="annot">` and followed by a small superscript marker
  # (`ᵃ`, `ᵇ`, ...). The Stimulus `annotation-highlight` controller on
  # the parent grid pairs the marker with its margin entry on hover.
  #
  # `base_index` is the chapter-wide note offset for this verse — its
  # first note is the (base_index)-th note in the chapter. The view
  # threads this through to give every marker on the page a unique
  # letter.
  #
  # If an anchor phrase doesn't appear verbatim in the body (Calvin
  # George's spelling can drift slightly from the modern KJV main text)
  # we render the marker at the END of the verse instead, so the note
  # is still visually associated.
  def render_verse_body_with_anchors(unit, notes, base_index = 0)
    body = unit.body.dup
    return body.html_safe if notes.empty?

    matches = []
    trailing = []
    notes.each_with_index do |note, i|
      idx = base_index + i
      anchor = note.anchor_text.to_s.strip
      pos = anchor.empty? ? nil : body.index(anchor)
      if pos
        matches << [pos, anchor.length, idx]
      else
        trailing << idx
      end
    end

    # Insert from right to left so earlier insertions don't shift
    # later positions.
    matches.sort_by { |m| -m[0] }.each do |start, len, idx|
      anchor_text = body[start, len]
      body = body[0...start] +
             %(<span class="annot" data-annot="#{idx}">#{anchor_text}</span>) +
             marker_html(idx) +
             body[(start + len)..]
    end

    trailing.each { |idx| body << marker_html(idx) }

    body.html_safe
  end

  # Renders the marginal-notes column for a single verse — one
  # `<aside>` containing a list with each note prefixed by its marker
  # letter and tagged with the same `data-annot` so the highlight
  # controller can pair it with its anchor in the verse text.
  #
  # `base_index` is the same chapter-wide offset passed to
  # `render_verse_body_with_anchors`.
  def render_verse_marginal_notes(notes, base_index = 0)
    return "".html_safe if notes.empty?

    items = notes.each_with_index.map do |note, i|
      idx = base_index + i
      letter = annot_letter(idx)
      type_pill = note_type_pill(note.note_type)
      %(<li class="annot-note text-sm leading-snug font-serif text-[var(--color-ink-soft)] mb-3 last:mb-0" data-annot="#{idx}">
          <sup class="annot-mark text-xs not-italic mr-1">#{letter}</sup>#{type_pill}<span class="annot-body">#{ERB::Util.h(note.body)}</span>
        </li>)
    end

    %(<ul class="list-none p-0">#{items.join}</ul>).html_safe
  end

  # Renders the verse body with each note's anchor phrase wrapped in a
  # tooltip-bearing span. Used by the parallel reader, where there's
  # no room for a margin column — the note appears as a styled hover
  # popover instead. The popover content lives in `data-tooltip`; the
  # `title` attribute mirrors it for accessibility / mobile fallback.
  def render_verse_body_with_tooltips(unit, notes)
    body = unit.body.dup
    return body.html_safe if notes.empty?

    matches = []
    notes.each do |note|
      anchor = note.anchor_text.to_s.strip
      pos = anchor.empty? ? nil : body.index(anchor)
      matches << [pos, anchor.length, note] if pos
    end

    matches.sort_by { |m| -m[0] }.each do |start, len, note|
      anchor_text = body[start, len]
      tip = ERB::Util.h(note.body)
      body = body[0...start] +
             %(<span class="annot-tooltip" tabindex="0" data-tooltip="#{tip}" title="#{tip}">#{anchor_text}</span>) +
             body[(start + len)..]
    end

    body.html_safe
  end

  # True if any verse in the collection has any notes attached. Used
  # to skip the margin column entirely when there's nothing to show
  # (so the prose centers on the page instead of being pulled left).
  def any_notes?(units)
    units.any? { |u| u.work_unit_notes.any? }
  end

  # Human-readable verse-range label for a pericope, computed from its
  # int4range over canonical_refs.ord. Returns e.g. "Gen 6:9–11:32"
  # or nil if the range can't be resolved.
  def pericope_range_label(pericope)
    cw = pericope.canonical_work
    return nil unless cw && pericope.canonical_range
    start_ord = pericope.canonical_range.begin
    end_ord   = pericope.canonical_range.end - 1  # int4range is half-open
    refs = CanonicalRef.where(canonical_work_id: cw.id, ord: [start_ord, end_ord]).index_by(&:ord)
    s = refs[start_ord]
    e = refs[end_ord]
    return nil unless s && e
    abbr = cw.sbl_abbreviation.presence || cw.display_title
    if s.hierarchy[0] == e.hierarchy[0]
      "#{abbr} #{s.hierarchy[0]}:#{s.hierarchy[1]}–#{e.hierarchy[1]}"
    else
      "#{abbr} #{s.hierarchy[0]}:#{s.hierarchy[1]}–#{e.hierarchy[0]}:#{e.hierarchy[1]}"
    end
  end

  private

  # Superscript letter marker (ᵃ ᵇ ᶜ … ᶻ ᵃᵃ ᵃᵇ …) for note index N.
  # Markers are unique within a chapter via base-26 (bijective) lettering:
  # 0..25 = a..z, 26..51 = aa..az, 52..77 = ba..bz, etc. The chapter
  # view threads a chapter-wide counter through the helpers so every
  # marker on the page is visually unique.
  ANNOT_LETTERS = %w[ᵃ ᵇ ᶜ ᵈ ᵉ ᶠ ᵍ ʰ ⁱ ʲ ᵏ ˡ ᵐ ⁿ ᵒ ᵖ ᵠ ʳ ˢ ᵗ ᵘ ᵛ ʷ ˣ ʸ ᶻ].freeze

  def annot_letter(idx)
    return ANNOT_LETTERS[idx] if idx < 26

    # Bijective base-26: keep dividing by 26 (with 1-offset) to get
    # the next significant letter.
    chars = []
    n = idx
    loop do
      chars.unshift(ANNOT_LETTERS[n % 26])
      n = n / 26 - 1
      break if n < 0
    end
    chars.join
  end

  def marker_html(idx)
    %(<sup class="annot-mark" data-annot="#{idx}">#{annot_letter(idx)}</sup>)
  end

  # A small italic prefix that hints at the note's type. The "Heb." /
  # "Or," prefix already lives in the body for translation/textual
  # notes, so those don't get a redundant pill.
  def note_type_pill(type)
    case type
    when "translation", "textual" then ""
    when "explanation"            then %(<em class="annot-pill text-[var(--color-ink-soft)] opacity-70 mr-1">note:</em>)
    when "cross_reference"        then %(<em class="annot-pill text-[var(--color-ink-soft)] opacity-70 mr-1">cf.</em>)
    when "editorial"              then %(<em class="annot-pill text-[var(--color-ink-soft)] opacity-70 mr-1">ed.</em>)
    else ""
    end
  end
end
