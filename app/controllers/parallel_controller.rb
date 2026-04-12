class ParallelController < ApplicationController
  allow_unauthenticated_access only: [:show, :show_daf]

  # Cold-start default — used when nothing is in `params[:works]`. The
  # picker form on the parallel page lets the user add more columns or
  # swap them out. Contextual "Read in parallel" links from the single-
  # work reader override this with `current_work + one companion`.
  DEFAULT_WORKS = %w[bsb wlc].freeze

  # GET /parallel/:book_slug/:chapter
  # GET /parallel/:book_slug/:chapter/:verse
  # GET /parallel/:book_slug/:chapter/:from-:to
  # GET /parallel/:book_slug/:from_ch.:from_v-:to_ch.:to_v
  #
  # Renders N works (>= 1) side-by-side aligned by canonical_ref. The
  # first work in the `works` param is the "primary": its work_units
  # define the row order, and every other column is mapped onto the
  # primary's canonical_refs via CanonicalRef#equivalent_in.
  #
  # Splits, merges, and missing verses are handled explicitly:
  #
  #   * split   (1→N): the secondary column shows all N verses joined.
  #   * merge   (N→1): the same secondary verse appears in each of the
  #                    N primary rows; the view de-duplicates contiguous
  #                    repeats so the merged text only renders once.
  #   * missing       : the cell renders an em-dash placeholder.
  #
  # The `works` param accepts both `?works=a,b,c` (comma-string) and
  # `?works[]=a&works[]=b` (array form, used by the picker form's
  # checkboxes).
  def show
    @selected_slugs = parse_works_param
    @works = @selected_slugs.map { |s| Work.find_by(slug: s) }.compact
    raise ActiveRecord::RecordNotFound, "no works" if @works.empty?

    @book_slug = params[:book_slug]
    @canonical_works = @works.each_with_object({}) do |w, h|
      h[w.id] = resolve_canonical_work(w, @book_slug)
    end

    primary    = @works.first
    primary_cw = @canonical_works[primary.id]
    raise ActiveRecord::RecordNotFound, "no book #{@book_slug.inspect} in #{primary.slug}" unless primary_cw

    @primary_canonical_work = primary_cw
    @range_kind, @range_label = compute_range_label

    @primary_units = fetch_primary_units(primary, primary_cw)
    if @primary_units.empty?
      raise ActiveRecord::RecordNotFound, "nothing in #{primary.slug} #{@book_slug} #{@range_label}"
    end

    @rows = build_rows(primary, @primary_units)

    # All works the user can pick from in the form. Restricted to
    # scripture for now (commentaries don't have canonical_ref alignment).
    @available_works = Work.where(work_type: %w[scripture_translation scripture_original])
                           .order(:slug)
                           .to_a
  end

  # GET /parallel/:book_slug/:daf?works=bavli,soncino-bavli
  # Talmud parallel reader — shows multiple Talmud works side-by-side
  # for a single daf (e.g., Hebrew Gemara + Soncino English).
  TALMUD_DEFAULT_WORKS = %w[bavli soncino-bavli].freeze

  def show_daf
    @selected_slugs = parse_works_param(TALMUD_DEFAULT_WORKS)
    @works = @selected_slugs.map { |s| Work.find_by(slug: s) }.compact
    raise ActiveRecord::RecordNotFound, "no works" if @works.empty?

    @book_slug = params[:book_slug]
    match = params[:daf].match(/\A(\d+)([ab])\z/)
    raise ActiveRecord::RecordNotFound, "invalid daf" unless match
    @daf_number = match[1].to_i
    @amud = match[2] == "a" ? 1 : 2
    @daf_label = params[:daf]
    @is_talmud = true

    # Resolve canonical work
    primary = @works.first
    @canonical_works = @works.each_with_object({}) do |w, h|
      h[w.id] = resolve_canonical_work(w, @book_slug)
    end
    primary_cw = @canonical_works[primary.id]
    raise ActiveRecord::RecordNotFound, "no tractate #{@book_slug}" unless primary_cw
    @primary_canonical_work = primary_cw

    # Fetch units for this daf from each work
    @daf_columns = @works.map do |w|
      cw = @canonical_works[w.id] || primary_cw
      units = WorkUnit.joins(:canonical_ref)
                .where(work_id: w.id, canonical_refs: { canonical_work_id: cw.id })
                .where("canonical_refs.hierarchy[1] = ? AND canonical_refs.hierarchy[2] = ?",
                       @daf_number, @amud)
                .order("canonical_refs.ord")
                .includes(:canonical_ref)
                .to_a
      { work: w, units: units, body: units.map(&:body).join(" ") }
    end

    # Prev/next daf navigation
    all_amudim = CanonicalRef
                   .where(canonical_work_id: primary_cw.id)
                   .distinct
                   .pluck(Arel.sql("hierarchy[1], hierarchy[2]"))
                   .sort_by { |d, a| [d, a] }
                   .uniq
    current_idx = all_amudim.index([@daf_number, @amud])
    @prev_daf = current_idx && current_idx > 0 ? all_amudim[current_idx - 1] : nil
    @next_daf = current_idx ? all_amudim[current_idx + 1] : nil

    # Available Talmud works for the picker (exclude xref-only works)
    hidden = %w[ein-mishpat-bavli mesoret-hashas-bavli]
    @available_works = Work.where(slug: DafController::TALMUD_SLUG_TO_GEMARA.keys + ["bavli"])
                           .where.not(slug: hidden)
                           .order(:title).to_a

    render :show_daf
  end

  private

  def parse_works_param(defaults = DEFAULT_WORKS)
    raw = params[:works]
    case raw
    when Array  then raw.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    when String then raw.split(",").map(&:strip).reject(&:blank?).uniq
    else             defaults.dup
    end
  end

  def resolve_canonical_work(work, book_slug)
    cw = CanonicalWork
           .joins(canonical_refs: :work_units)
           .where(work_units: { work_id: work.id })
           .where(book_key: book_slug)
           .group("canonical_works.id")
           .order(Arel.sql("COUNT(work_units.id) DESC"))
           .select("canonical_works.*")
           .first
    cw || CanonicalWork.find_by(slug: book_slug)
  end

  # Returns [kind, label] for the requested passage. `kind` is one of
  # :chapter, :verse, :range, :cross_range — used by the view to title
  # the page and emit the right "next/prev" navigation.
  def compute_range_label
    if params[:from_ch]
      [:cross_range,
       "#{params[:from_ch]}:#{params[:from_v]}-#{params[:to_ch]}:#{params[:to_v]}"]
    elsif params[:from]
      [:range, "#{params[:chapter]}:#{params[:from]}-#{params[:to]}"]
    elsif params[:verse]
      [:verse, "#{params[:chapter]}:#{params[:verse]}"]
    else
      [:chapter, params[:chapter].to_s]
    end
  end

  # Fetch the primary work_units for the requested passage. The four
  # URL shapes (chapter / verse / intra-chapter range / cross-chapter
  # range) all funnel through here.
  def fetch_primary_units(primary, primary_cw)
    base = WorkUnit
             .joins(:canonical_ref)
             .where(work_id: primary.id,
                    canonical_refs: { canonical_work_id: primary_cw.id })
             .order("canonical_refs.ord")
             .includes(:canonical_ref, :work_unit_notes)

    case @range_kind
    when :cross_range
      start_ord = canonical_ord_for(primary_cw, params[:from_ch].to_i, params[:from_v].to_i)
      end_ord   = canonical_ord_for(primary_cw, params[:to_ch].to_i,   params[:to_v].to_i)
      return [] unless start_ord && end_ord
      base.where("canonical_refs.ord BETWEEN ? AND ?", start_ord, end_ord).to_a
    when :range
      base.where("canonical_refs.hierarchy[1] = ? AND
                  canonical_refs.hierarchy[2] BETWEEN ? AND ?",
                 params[:chapter].to_i, params[:from].to_i, params[:to].to_i).to_a
    when :verse
      base.where("canonical_refs.hierarchy[1] = ? AND
                  canonical_refs.hierarchy[2] = ?",
                 params[:chapter].to_i, params[:verse].to_i).to_a
    else # :chapter
      base.where("canonical_refs.hierarchy[1] = ?", params[:chapter].to_i).to_a
    end
  end

  def canonical_ord_for(canonical_work, chapter, verse)
    CanonicalRef
      .where(canonical_work_id: canonical_work.id)
      .where("hierarchy[1] = ? AND hierarchy[2] = ?", chapter, verse)
      .pick(:ord)
  end

  # Build a row per primary unit with each work's mapped work_units.
  #
  # Row shape:
  #   { ref: CanonicalRef, cells: { work_id => [WorkUnit, ...] } }
  def build_rows(primary, primary_units)
    primary_units.map do |unit|
      ref = unit.canonical_ref
      cells = { primary.id => [unit] }

      @works.drop(1).each do |other|
        other_cw = @canonical_works[other.id]
        cells[other.id] = other_cw.nil? ? [] : equivalent_units_for(ref, other, other_cw)
      end

      { ref: ref, cells: cells }
    end
  end

  # Map a primary canonical_ref into WorkUnits in the target Work via
  # CanonicalRef#equivalent_in (TVTMS-aware).
  def equivalent_units_for(primary_ref, other_work, other_cw)
    target_scheme = other_cw.versification_scheme
    equivalents = primary_ref.equivalent_in(target_scheme)
    return [] if equivalents.empty?

    WorkUnit
      .where(work_id: other_work.id, canonical_ref_id: equivalents.map(&:id))
      .includes(:canonical_ref, :work_unit_notes)
      .to_a
      .sort_by { |u| u.canonical_ref.ord }
  end
end
