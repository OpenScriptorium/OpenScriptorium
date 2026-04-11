class DafController < ApplicationController
  allow_unauthenticated_access only: [:show]

  before_action :load_work_and_book
  before_action :parse_daf

  # GET /:work_slug/:book_slug/:daf (e.g. /bavli/berakhot/2a)
  def show
    @gemara_units = fetch_units(@gemara_work)
    if @gemara_units.empty?
      raise ActiveRecord::RecordNotFound,
            "No daf #{@daf_label} in #{@canonical_work.title}"
    end

    rashi_grouped   = fetch_units(@rashi_work).group_by(&:canonical_ref_id)
    tosafot_grouped = fetch_units(@tosafot_work).group_by(&:canonical_ref_id)

    @segments = @gemara_units.map do |unit|
      ref_id = unit.canonical_ref_id
      {
        ref: unit.canonical_ref,
        gemara: unit,
        rashi: rashi_grouped[ref_id] || [],
        tosafot: tosafot_grouped[ref_id] || [],
        mishnah: unit.markup&.dig("mishnah") == true
      }
    end

    # Margin commentaries (Rashash, Maharsha, Gilyon HaShas, etc.)
    @margin_works = fetch_margin_commentaries

    compute_navigation
  end

  private

  def load_work_and_book
    slug = params[:work_slug]

    # Normalize: if the user navigated via rashi-bavli or tosafot-bavli,
    # treat it as the gemara view (the Vilna layout shows all three).
    if slug.start_with?("rashi-")
      gemara_slug = slug.sub("rashi-", "")
    elsif slug.start_with?("tosafot-")
      gemara_slug = slug.sub("tosafot-", "")
    else
      gemara_slug = slug
    end

    @gemara_work  = Work.find_by!(slug: gemara_slug)
    @rashi_work   = Work.find_by(slug: "rashi-#{gemara_slug}")
    @tosafot_work = Work.find_by(slug: "tosafot-#{gemara_slug}")

    @canonical_work = CanonicalWork
                        .joins(canonical_refs: :work_units)
                        .where(work_units: { work_id: @gemara_work.id })
                        .where(book_key: params[:book_slug])
                        .group("canonical_works.id")
                        .order(Arel.sql("COUNT(work_units.id) DESC"))
                        .select("canonical_works.*")
                        .first
    @canonical_work ||= CanonicalWork.find_by(slug: params[:book_slug])
    raise ActiveRecord::RecordNotFound, "no tractate #{params[:book_slug]}" unless @canonical_work
  end

  def parse_daf
    match = params[:daf].match(/\A(\d+)([ab])\z/)
    raise ActiveRecord::RecordNotFound, "invalid daf" unless match
    @daf_number = match[1].to_i
    @amud       = match[2] == "a" ? 1 : 2
    @daf_label  = "#{@daf_number}#{match[2]}"
  end

  def fetch_units(work)
    return [] unless work
    WorkUnit
      .joins(:canonical_ref)
      .where(canonical_refs: { canonical_work_id: @canonical_work.id })
      .where(work_id: work.id)
      .where("canonical_refs.hierarchy[1] = ? AND canonical_refs.hierarchy[2] = ?",
             @daf_number, @amud)
      .order("canonical_refs.ord, work_units.label")
      .includes(:canonical_ref)
      .to_a
  end

  MARGIN_SLUGS = %w[
    rashash-bavli maharsha-halachot maharsha-agadot
    gilyon-hashas chokhmat-shlomo hagahot-yaavetz piskei-tosafot
  ].freeze

  def fetch_margin_commentaries
    MARGIN_SLUGS.filter_map do |slug|
      work = Work.find_by(slug: slug)
      next unless work
      units = fetch_units(work)
      next if units.empty?
      { work: work, units: units }
    end
  end

  def compute_navigation
    all_amudim = CanonicalRef
                   .where(canonical_work_id: @canonical_work.id)
                   .distinct
                   .pluck(Arel.sql("hierarchy[1], hierarchy[2]"))
                   .sort_by { |d, a| [d, a] }
                   .uniq

    current_idx = all_amudim.index([@daf_number, @amud])
    @prev_daf = current_idx && current_idx > 0 ? all_amudim[current_idx - 1] : nil
    @next_daf = current_idx ? all_amudim[current_idx + 1] : nil
  end
end
