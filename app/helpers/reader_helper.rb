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
    return (render_red_letter_spans? ? apply_red_letter_spans(body, unit.markup&.dig("red_letter_positions")).html_safe : body.html_safe) if notes.empty?

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

    # Notes with no anchor text: wrap the entire verse body so the
    # whole verse highlights on hover (e.g. Brenton's LXX notes).
    if trailing.any? && matches.empty?
      body = %(<span class="annot annot-verse" data-annot="#{trailing.first}">#{body}</span>)
      trailing.each { |idx| body << marker_html(idx) }
    else
      trailing.each { |idx| body << marker_html(idx) }
    end

    # Apply red-letter wrapping AFTER anchor insertion. We can't
    # naively split on whitespace because the body now contains HTML
    # tags. Instead, walk the string tracking tag depth and wrap each
    # top-level text word at a red-letter position.
    if render_red_letter_spans? && has_red_letter?(unit)
      body = apply_red_letter_to_html(body, unit.markup["red_letter_positions"])
    end

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
             %(<span class="annot-tooltip" tabindex="0" data-tooltip="#{tip}" title="#{tip}">#{anchor_text}<span class="sr-only"> (note: #{tip})</span></span>) +
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

  # ----------------------------------------------------------------
  # Cross-reference rendering
  # ----------------------------------------------------------------

  # The set of cross-reference datasets the current visitor has opted
  # into. Stored as a comma-separated string in the `xref_datasets`
  # cookie (or in users.preferences once auth is wired up). Default
  # is empty — cross-references are opt-in so the default reading
  # experience stays uncluttered.
  def current_xref_datasets
    raw = cookies[:xref_datasets].to_s
    raw.split(",").map(&:strip).reject(&:empty?)
  end

  # All datasets currently present in cross_references, used to drive
  # the picker UI. Cached per-request via @available_xref_datasets so
  # we don't requery on every helper call.
  def available_xref_datasets
    @available_xref_datasets ||= CrossReference.distinct.pluck(:source_dataset).compact.sort
  end

  # Display labels for known xref datasets — falls back to a
  # humanized version of the slug for anything we haven't tagged.
  XREF_DATASET_LABELS = {
    "bsb_inline"     => "BSB editorial",
    "openbible"      => "OpenBible.info",
    "tsk"            => "Treasury of Scripture Knowledge",
    "sefaria_links"  => "Sefaria links",
    "sefaria"        => "Sefaria"
  }.freeze

  def xref_dataset_label(slug)
    XREF_DATASET_LABELS[slug] || slug.to_s.tr("_", " ").capitalize
  end

  # Returns the cross_references whose source range overlaps the
  # given canonical_ref's ord, filtered by the user's selected
  # datasets. Empty array if no datasets are selected — keeps the
  # default reader uncluttered.
  #
  # Batch preload: call preload_xrefs_for_chapter! once with all
  # verses, then per-verse lookups are just hash reads.
  def preload_xrefs_for_chapter!(verses)
    datasets = current_xref_datasets
    return if datasets.empty? || verses.empty?

    @xref_cache ||= {}
    @reverse_xref_cache ||= {}

    cw_id = verses.first.canonical_ref.canonical_work_id
    ords = verses.map { |v| v.canonical_ref.ord }
    min_ord, max_ord = ords.minmax

    # Forward xrefs: source_range overlaps any verse ord
    forward = CrossReference.approved
                .where(source_dataset: datasets, source_canonical_work_id: cw_id)
                .where("source_range && int4range(?, ?)", min_ord, max_ord + 1)
                .includes(:target_canonical_work)
                .to_a

    # Reverse xrefs: target_range overlaps any verse ord
    reverse = CrossReference.approved
                .where(source_dataset: datasets, target_canonical_work_id: cw_id)
                .where("target_range && int4range(?, ?)", min_ord, max_ord + 1)
                .includes(:source_canonical_work)
                .to_a

    # Bucket by ord
    ords.each do |ord|
      key = [verses.find { |v| v.canonical_ref.ord == ord }&.canonical_ref&.id, datasets]
      @xref_cache[key] = forward.select { |xr| xr.source_range.cover?(ord) }
      @reverse_xref_cache[key] = reverse.select { |xr| xr.target_range.cover?(ord) }
    end
  end

  def cross_references_for(canonical_ref)
    datasets = current_xref_datasets
    return [] if datasets.empty? || canonical_ref.nil?

    @xref_cache ||= {}
    key = [canonical_ref.id, datasets]
    return @xref_cache[key] if @xref_cache.key?(key)

    @xref_cache[key] = CrossReference
                         .approved
                         .where(source_dataset: datasets)
                         .for_source_ord(canonical_ref.canonical_work_id, canonical_ref.ord)
                         .includes(target_canonical_work: {})
                         .to_a
  end

  # Reverse cross-references: passages that link TO this verse.
  def reverse_cross_references_for(canonical_ref)
    datasets = current_xref_datasets
    return [] if datasets.empty? || canonical_ref.nil?

    @reverse_xref_cache ||= {}
    key = [canonical_ref.id, datasets]
    return @reverse_xref_cache[key] if @reverse_xref_cache.key?(key)

    @reverse_xref_cache[key] = CrossReference
                                 .approved
                                 .where(source_dataset: datasets)
                                 .for_target_ord(canonical_ref.canonical_work_id, canonical_ref.ord)
                                 .includes(source_canonical_work: {})
                                 .to_a
  end

  # Format a reverse cross-reference's SOURCE as an SBL-style citation.
  def format_xref_source(xref)
    cw = xref.source_canonical_work
    start_ord = xref.source_range.begin
    end_ord   = xref.source_range.end - 1
    refs = CanonicalRef.where(canonical_work_id: cw.id, ord: [start_ord, end_ord]).index_by(&:ord)
    s = refs[start_ord]
    e = refs[end_ord]
    return cw.display_title unless s
    abbr = cw.sbl_abbreviation.presence || cw.display_title
    if e.nil? || s.id == e.id
      cw.format_citation(s.hierarchy)
    elsif s.hierarchy[0] == e.hierarchy[0]
      "#{abbr} #{s.hierarchy[0]}:#{s.hierarchy[1]}–#{e.hierarchy[1]}"
    else
      "#{abbr} #{s.hierarchy[0]}:#{s.hierarchy[1]}–#{e.hierarchy[0]}:#{e.hierarchy[1]}"
    end
  end

  # Returns a reader-link path for a reverse xref's source.
  def xref_source_path(xref)
    cw = xref.source_canonical_work
    start_ord = xref.source_range.begin
    start_ref = CanonicalRef.where(canonical_work_id: cw.id, ord: start_ord).first
    return "#" unless start_ref
    chapter = start_ref.hierarchy[0]
    work_slug = resolve_work_for_canonical_work(cw)
    reader_chapter_path(work_slug, cw.book_key, chapter, anchor: "v#{start_ref.hierarchy[1]}")
  end

  # Format a cross-reference's target as an SBL-style citation
  # ("John 1:1–5"). The target_range is an int4range over
  # canonical_refs.ord; we resolve the start and end ords to
  # canonical_refs and format their hierarchies.
  def format_xref_target(xref)
    cw = xref.target_canonical_work
    start_ord = xref.target_range.begin
    end_ord   = xref.target_range.end - 1
    refs = CanonicalRef.where(canonical_work_id: cw.id, ord: [start_ord, end_ord]).index_by(&:ord)
    s = refs[start_ord]
    e = refs[end_ord]
    return cw.display_title unless s
    abbr = cw.sbl_abbreviation.presence || cw.display_title
    if e.nil? || s.id == e.id
      "#{abbr} #{s.hierarchy[0]}:#{s.hierarchy[1]}"
    elsif s.hierarchy[0] == e.hierarchy[0]
      "#{abbr} #{s.hierarchy[0]}:#{s.hierarchy[1]}–#{e.hierarchy[1]}"
    else
      "#{abbr} #{s.hierarchy[0]}:#{s.hierarchy[1]}–#{e.hierarchy[0]}:#{e.hierarchy[1]}"
    end
  end

  # Returns a reader-link path for a cross-reference target. Uses the
  # current Work's slug if it has work_units in the target's
  # canonical_work, otherwise falls back to BSB (the default English
  # work). The fallback is so xrefs to OT books from a NT-only work
  # still resolve to a readable page.
  def xref_target_path(xref)
    cw = xref.target_canonical_work
    start_ord = xref.target_range.begin
    start_ref = CanonicalRef.where(canonical_work_id: cw.id, ord: start_ord).first
    return "#" unless start_ref
    chapter = start_ref.hierarchy[0]
    work_slug = resolve_work_for_canonical_work(cw)
    reader_chapter_path(work_slug, cw.book_key, chapter, anchor: "v#{start_ref.hierarchy[1]}")
  end

  # ----------------------------------------------------------------
  # Apparatus rendering
  # ----------------------------------------------------------------

  # Returns VariantUnit rows for a canonical_ref, with readings and
  # their manuscript witnesses eager-loaded. Cached per-request so
  # the chapter view doesn't re-query per verse.
  def apparatus_for(canonical_ref)
    return [] if canonical_ref.nil?

    @apparatus_cache ||= {}
    return @apparatus_cache[canonical_ref.id] if @apparatus_cache.key?(canonical_ref.id)

    @apparatus_cache[canonical_ref.id] = VariantUnit
      .where(canonical_ref_id: canonical_ref.id)
      .includes(readings: { reading_witnesses: :manuscript })
      .order(:id)
      .to_a
  end

  # ----------------------------------------------------------------
  # Red-letter rendering
  # ----------------------------------------------------------------

  # True if the visitor has red-letter display enabled (cookie).
  # Accepts both "on" (color only) and "accessible" (color + underline).
  def red_letter_enabled?
    %w[on accessible].include?(cookies[:red_letter].to_s.strip)
  end

  # Whether to render red-letter spans in the HTML. Always true when
  # the work has red-letter data — the CSS [data-red-letter] attribute
  # controls visibility, so spans are harmless when the toggle is off.
  # This lets the JS toggle work instantly without a page reload.
  def render_red_letter_spans?
    return false unless @work
    @render_rl_spans = @work.has_red_letter? unless defined?(@render_rl_spans)
    @render_rl_spans
  end

  # Returns true if the work_unit has red-letter markup and ALL of
  # its words are marked (i.e. the whole verse is Jesus speaking).
  # Used to apply a single `rl` class to the whole verse element
  # rather than per-word spans — simpler and works with the anchor
  # renderer which doesn't support inline spans.
  def fully_red_letter?(unit)
    positions = unit.markup&.dig("red_letter_positions")
    return false if positions.blank?
    word_count = unit.body.to_s.split(/\s+/).size
    positions.size >= word_count
  end

  # Returns true if the work_unit has ANY red-letter markup.
  def has_red_letter?(unit)
    unit.markup&.dig("red_letter_positions").present?
  end

  # Wraps words at the positions listed in the work_unit's
  # markup["red_letter_positions"] in `<span class="rl">` so the
  # CSS `[data-red-letter] .rl` rule can color them. The positions
  # are 1-based indices into the whitespace-split body text.
  # Returns the body string with rl spans inserted, or the original
  # body if there are no red-letter positions.
  def render_body_with_red_letter(unit)
    positions = unit.markup&.dig("red_letter_positions")
    body = unit.body.to_s
    return body if positions.blank?

    pos_set = positions.to_set
    words = body.split(/(\s+)/)  # split preserving whitespace
    word_idx = 0
    result = words.map do |token|
      if token.match?(/\S/)
        word_idx += 1
        if pos_set.include?(word_idx)
          %(<span class="rl">#{ERB::Util.h(token)}</span>)
        else
          ERB::Util.h(token)
        end
      else
        token  # whitespace, pass through
      end
    end
    result.join.html_safe
  end

  # Wraps words at red-letter positions in `<span class="rl">`,
  # operating on the raw body string (no HTML tags). Used for the
  # simple non-notes rendering path.
  def apply_red_letter_spans(body, positions)
    return body if positions.blank?
    pos_set = positions.to_set
    words = body.split(/(\s+)/)
    word_idx = 0
    words.map do |token|
      if token.match?(/\S/)
        word_idx += 1
        pos_set.include?(word_idx) ? %(<span class="rl">#{token}</span>) : token
      else
        token
      end
    end.join
  end

  # Like apply_red_letter_spans but operates on an HTML string that
  # may contain tags (e.g. <span class="annot">). We scan the string
  # for text nodes (outside tags), count visible words across the
  # whole verse, and wrap the Nth word if its position is in the
  # red-letter set. Tags pass through unmodified.
  def apply_red_letter_to_html(html, positions)
    return html if positions.blank?
    pos_set = positions.to_set
    word_idx = 0
    # Split into tag-tokens and text-tokens
    html.gsub(/([^<]+)|(<[^>]*>)/) do
      if $2 # HTML tag — pass through
        $2
      else  # text node
        $1.gsub(/(\S+)/) do |word|
          word_idx += 1
          pos_set.include?(word_idx) ? %(<span class="rl">#{word}</span>) : word
        end
      end
    end
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

  # Find the best work slug to link to for a given canonical_work.
  # Prefers the current @work if it has units there, otherwise finds
  # any work that does. Cached per-request.
  def resolve_work_for_canonical_work(cw)
    @work_for_cw_cache ||= {}
    return @work_for_cw_cache[cw.id] if @work_for_cw_cache.key?(cw.id)

    # Try current work first
    if @work && WorkUnit.where(work_id: @work.id).joins(:canonical_ref)
                        .where(canonical_refs: { canonical_work_id: cw.id }).exists?
      return @work_for_cw_cache[cw.id] = @work.slug
    end

    # Find any work that has units for this canonical_work
    slug = WorkUnit.joins(:canonical_ref, :work)
                   .where(canonical_refs: { canonical_work_id: cw.id })
                   .pick("works.slug")
    @work_for_cw_cache[cw.id] = slug || "bsb"
  end

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
