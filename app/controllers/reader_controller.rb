class ReaderController < ApplicationController
  allow_unauthenticated_access only: [:book, :chapter, :verse, :range, :cross_chapter_range]

  before_action :load_work_and_book

  # /:work_slug/:book_slug — book overview
  def book
    @chapters = WorkUnit
                  .joins(:canonical_ref)
                  .where(canonical_refs: { canonical_work_id: @canonical_work.id })
                  .where(work_id: @work.id)
                  .pluck(Arel.sql("DISTINCT canonical_refs.hierarchy[1]"))
                  .compact
                  .sort
  end

  # /:work_slug/:book_slug/:chapter — chapter view
  def chapter
    @chapter = params[:chapter].to_i
    @verses  = WorkUnit
                 .joins(:canonical_ref)
                 .where(canonical_refs: { canonical_work_id: @canonical_work.id })
                 .where(work_id: @work.id)
                 .where("canonical_refs.hierarchy[1] = ?", @chapter)
                 .order("canonical_refs.ord")
                 .includes(:canonical_ref, :work_unit_notes)

    if @verses.empty?
      raise ActiveRecord::RecordNotFound, "No chapter #{@chapter} in #{@canonical_work.display_title}"
    end

    @pericope_starts = pericope_starts_for(@verses)
  end

  # /:work_slug/:book_slug/:chapter/:verse — single verse permalink
  def verse
    @chapter = params[:chapter].to_i
    @verse_n = params[:verse].to_i
    @verse = WorkUnit
               .joins(:canonical_ref)
               .where(canonical_refs: { canonical_work_id: @canonical_work.id })
               .where(work_id: @work.id)
               .where("canonical_refs.hierarchy[1] = ? AND canonical_refs.hierarchy[2] = ?",
                      @chapter, @verse_n)
               .includes(:canonical_ref, :work_unit_notes)
               .first
    raise ActiveRecord::RecordNotFound unless @verse
  end

  # /:work_slug/:book_slug/:chapter/:from-:to — verse range within a chapter
  def range
    @chapter = params[:chapter].to_i
    @from    = params[:from].to_i
    @to      = params[:to].to_i

    if @to < @from
      raise ActiveRecord::RecordNotFound, "range :to must be >= :from"
    end

    @verses = WorkUnit
                .joins(:canonical_ref)
                .where(canonical_refs: { canonical_work_id: @canonical_work.id })
                .where(work_id: @work.id)
                .where("canonical_refs.hierarchy[1] = ? AND
                        canonical_refs.hierarchy[2] BETWEEN ? AND ?",
                       @chapter, @from, @to)
                .order("canonical_refs.ord")
                .includes(:canonical_ref, :work_unit_notes)

    raise ActiveRecord::RecordNotFound if @verses.empty?

    @range_label = "#{@chapter}:#{@from}-#{@to}"
    @display_title = "#{@canonical_work.display_title} #{@range_label}"
  end

  # /:work_slug/:book_slug/:from_ch.:from_v-:to_ch.:to_v — cross-chapter range
  def cross_chapter_range
    @from_ch = params[:from_ch].to_i
    @from_v  = params[:from_v].to_i
    @to_ch   = params[:to_ch].to_i
    @to_v    = params[:to_v].to_i

    if (@to_ch < @from_ch) || (@to_ch == @from_ch && @to_v < @from_v)
      raise ActiveRecord::RecordNotFound, "cross-chapter range end must come after start"
    end

    # Compute ordinal-based bounds via the canonical_refs.ord column.
    # Look up the start and end canonical_refs and use their ord values.
    start_ord = canonical_ord(@from_ch, @from_v)
    end_ord   = canonical_ord(@to_ch,   @to_v)

    raise ActiveRecord::RecordNotFound unless start_ord && end_ord

    @verses = WorkUnit
                .joins(:canonical_ref)
                .where(canonical_refs: { canonical_work_id: @canonical_work.id })
                .where(work_id: @work.id)
                .where("canonical_refs.ord BETWEEN ? AND ?", start_ord, end_ord)
                .order("canonical_refs.ord")
                .includes(:canonical_ref, :work_unit_notes)

    raise ActiveRecord::RecordNotFound if @verses.empty?

    @range_label   = "#{@from_ch}:#{@from_v}-#{@to_ch}:#{@to_v}"
    @display_title = "#{@canonical_work.display_title} #{@range_label}"

    render :range
  end

  private

  def canonical_ord(chapter, verse)
    CanonicalRef
      .where(canonical_work_id: @canonical_work.id)
      .where("hierarchy[1] = ? AND hierarchy[2] = ?", chapter, verse)
      .pick(:ord)
  end

  # For each verse in the loaded chapter (or range), find any
  # pericopes from the work's traditions whose range starts at that
  # verse's ord. Returns a hash of `ord => [Pericope, ...]` so the
  # view can render the pericope name as a section heading just above
  # the verse where it begins. Returns an empty hash if the work has
  # no pericope traditions or no pericopes match.
  def pericope_starts_for(verses)
    return {} if @work.pericope_traditions.blank?
    return {} if verses.empty?

    ords = verses.map { |u| u.canonical_ref.ord }
    starts = Hash.new { |h, k| h[k] = [] }

    Pericope
      .where(canonical_work_id: @canonical_work.id, tradition: @work.pericope_traditions)
      .where("lower(canonical_range) = ANY(ARRAY[?])", ords)
      .ordered
      .each { |p| starts[p.canonical_range.begin] << p }

    starts
  end

  # Resolve the work and the canonical_work for the requested book.
  #
  # The book identifier in the URL is matched against canonical_works.book_key
  # (NOT slug), and we further constrain to canonical_works that actually
  # have work_units for the current Work. This lets multiple
  # canonical_works share a URL — e.g. both "psalms" (KJV scheme) and
  # "psalms-lxx" (LXX scheme) have book_key="psalms", so /bsb/psalms/9
  # resolves to KJV-Psalms (the only one BSB has units for) while
  # /rahlfs-lxx/psalms/9 resolves to LXX-Psalms.
  #
  # Where multiple canonical_works share a book_key for the same Work
  # (e.g. Rahlfs has both `joshua` — the JoshA fragments — and
  # `joshua-vaticanus-b` — the full B-text — under book_key="joshua"),
  # we pick the canonical_work with the most work_units in this Work.
  # This makes the "primary" recension win for the bare URL while the
  # secondary one is still reachable via its full slug.
  #
  # Falls back to a direct slug lookup so /rahlfs-lxx/joshua-vaticanus-b
  # and similar explicit-slug URLs still work.
  def load_work_and_book
    @work = Work.find_by!(slug: params[:work_slug])

    candidates = CanonicalWork
                   .joins(canonical_refs: :work_units)
                   .where(work_units: { work_id: @work.id })
                   .where(book_key: params[:book_slug])
                   .group("canonical_works.id")
                   .order(Arel.sql("COUNT(work_units.id) DESC"))
                   .select("canonical_works.*")

    @canonical_work = candidates.first
    @canonical_work ||= CanonicalWork.find_by(slug: params[:book_slug])
    raise ActiveRecord::RecordNotFound, "no book #{params[:book_slug].inspect}" unless @canonical_work
  end
end
