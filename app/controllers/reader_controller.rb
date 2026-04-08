class ReaderController < ApplicationController
  allow_unauthenticated_access only: [:book, :chapter, :verse]

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

  private

  def load_work_and_book
    @work = Work.find_by!(slug: params[:work_slug])
    @canonical_work = CanonicalWork.find_by!(slug: params[:book_slug])
  end
end
