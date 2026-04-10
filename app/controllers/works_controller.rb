class WorksController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]

  def index
    # Selected filters come from URL params and seed the form's
    # initial state. The actual filtering happens client-side in the
    # works-filter Stimulus controller — for ~10 works this is far
    # snappier than a server roundtrip on every input change, and
    # avoids re-running the per-work feature predicates (which each
    # cost an indexed query and add up under heavy import write
    # contention).
    @selected_features  = Array(params[:features]).select { |f| Work::FEATURE_DEFINITIONS.any? { |d| d[0] == f } }
    @selected_language  = params[:language].presence
    @selected_tradition = params[:tradition].presence
    @selected_type      = params[:type].presence

    @works = Work.includes(:license).order(:title).to_a

    @facet_languages  = @works.map(&:language).compact.uniq.sort
    @facet_traditions = @works.flat_map(&:traditions).compact.uniq.sort
    @facet_types      = @works.map(&:work_type).compact.uniq.sort

    # Pre-compute every work's feature flags once and freeze the
    # array. The view embeds them as data- attributes so the JS
    # filter has everything it needs without a server call.
    @feature_flags_by_work = @works.each_with_object({}) do |w, h|
      h[w.id] = w.feature_flags
    end
  end

  def show
    @work = Work.find_by!(slug: params[:slug])
    @canonical_works = CanonicalWork
                        .joins(canonical_refs: :work_units)
                        .where(work_units: { work_id: @work.id })
                        .distinct
                        .order(:position)
  end
end
