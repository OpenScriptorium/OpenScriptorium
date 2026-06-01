class LemmasController < ApplicationController
  allow_unauthenticated_access only: [:show]

  PER_PAGE = 50

  # /lemmas/:id — public word-study page. Header (lemma + translit + gloss)
  # plus a paginated concordance of every verse in an original-language
  # work where this lemma's words appear. Translation work_units are
  # excluded because their `words` rows follow source-language order, not
  # the translation's surface order; mixing them in would surface verses
  # twice (once in the original, once in each aligned translation).
  def show
    @lemma = Lemma.find(params[:id])
    @page = [params[:page].to_i, 1].max
    @per_page = PER_PAGE

    # Sibling homonyms: other Lemma rows with the same headword in the
    # same language. Empty for the common solo-entry case.
    @homonyms = Lemma.where(language: @lemma.language, lemma: @lemma.lemma)
                     .where.not(id: @lemma.id)
                     .order(:homonym_n, :id)
                     .to_a

    # Every work that has at least one word tagged with this lemma_id —
    # these become the source tabs on the page. Includes the original-
    # language work(s) plus any English/translation works whose words
    # were aligned back to the original lemma during their import (BSB,
    # KJV via Strong's, etc.). Default tab is the first work in the
    # lemma's own language.
    @available_sources = Work
      .joins(:words)
      .where(words: { lemma_id: @lemma.id })
      .distinct
      .order(:title)
      .pluck(:slug, :title, :language)

    if @available_sources.empty?
      @selected_source = nil
      @verses = []
      @total_count = 0
      @total_pages = 1
    else
      requested = params[:source].to_s
      @selected_source = @available_sources.find { |s, _, _| s == requested } ||
                         @available_sources.find { |_, _, l| l == @lemma.language } ||
                         @available_sources.first
      source_work = Work.find_by(slug: @selected_source[0])

      word_unit_id_subq = Word
        .where(lemma_id: @lemma.id, work_id: source_work.id)
        .select(:work_unit_id)
        .distinct

      sorted_units = WorkUnit
        .where(id: word_unit_id_subq)
        .joins(canonical_ref: :canonical_work)
        .order("canonical_works.position", "canonical_refs.ord")

      @total_count = sorted_units.count
      @total_pages = [(@total_count.to_f / @per_page).ceil, 1].max
      @verses = sorted_units
        .includes(:work, canonical_ref: :canonical_work)
        .offset((@page - 1) * @per_page)
        .limit(@per_page)
        .to_a
    end

    @related_lemmas =
      if @lemma.related_lemma_ids.present?
        Lemma.where(id: @lemma.related_lemma_ids).order(frequency: :desc).to_a
      else
        []
      end

    @lexicon_entries_by_source = LexiconEntry
      .where(lemma_id: @lemma.id)
      .includes(:license)
      .order(:source, :id)
      .group_by(&:source)

    # Distinct Strong's numbers attached to this lemma's words. Strong's
    # are stored inconsistently across importers (bare "7225" vs "H7225"
    # vs "H07225" vs "H72250"); `Strongs.normalize_set_with_counts`
    # collapses those variants and drops trailing-zero noise that drowns
    # in the canonical form's count.
    raw_strongs_counts = Word
      .where(lemma_id: @lemma.id)
      .where.not(strongs_number: [nil, ""])
      .group(:strongs_number)
      .count
    @strongs_numbers = Strongs.normalize_set_with_counts(raw_strongs_counts, language: @lemma.language)
  end
end
