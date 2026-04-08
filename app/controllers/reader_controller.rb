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
                 .includes(:canonical_ref)

    if @verses.empty?
      raise ActiveRecord::RecordNotFound, "No chapter #{@chapter} in #{@canonical_work.title}"
    end
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
               .includes(:canonical_ref)
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
                .includes(:canonical_ref)

    raise ActiveRecord::RecordNotFound if @verses.empty?

    @range_label = "#{@chapter}:#{@from}-#{@to}"
    @display_title = "#{@canonical_work.title} #{@range_label}"
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
                .includes(:canonical_ref)

    raise ActiveRecord::RecordNotFound if @verses.empty?

    @range_label   = "#{@from_ch}:#{@from_v}-#{@to_ch}:#{@to_v}"
    @display_title = "#{@canonical_work.title} #{@range_label}"

    render :range
  end

  private

  def canonical_ord(chapter, verse)
    CanonicalRef
      .where(canonical_work_id: @canonical_work.id)
      .where("hierarchy[1] = ? AND hierarchy[2] = ?", chapter, verse)
      .pick(:ord)
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
  # Falls back to a direct slug lookup so /bsb/psalms still works in
  # the rare case the book_key happens to match neither work but a
  # legacy URL is in someone's bookmarks.
  def load_work_and_book
    @work = Work.find_by!(slug: params[:work_slug])

    @canonical_work = CanonicalWork.used_by_work(@work.id)
                                   .where(book_key: params[:book_slug])
                                   .first

    @canonical_work ||= CanonicalWork.find_by(slug: params[:book_slug])
    raise ActiveRecord::RecordNotFound, "no book #{params[:book_slug].inspect}" unless @canonical_work
  end
end
