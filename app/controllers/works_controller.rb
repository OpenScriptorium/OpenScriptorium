class WorksController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]

  def index
    @selected_features  = Array(params[:features]).select { |f| Work::FEATURE_DEFINITIONS.any? { |d| d[0] == f } }
    @selected_language  = params[:language].presence
    @selected_tradition = params[:tradition].presence
    @selected_type      = params[:type].presence

    scope = Work.includes(:license).order(:title)
    scope = scope.where(language: @selected_language)  if @selected_language
    scope = scope.where(tradition: @selected_tradition) if @selected_tradition
    scope = scope.where(work_type: @selected_type)      if @selected_type
    all_works = scope.to_a

    # Feature filtering happens in Ruby — each predicate is one indexed
    # query and we have at most a few dozen works, so this is cheaper
    # than building a SQL union of EXISTS subqueries.
    @works = if @selected_features.any?
      all_works.select { |w| (@selected_features - w.feature_flags).empty? }
    else
      all_works
    end

    # Build the facets shown in the sidebar from the unfiltered set
    # so the user can always see what other options exist.
    @facet_languages  = Work.distinct.pluck(:language).compact.sort
    @facet_traditions = Work.distinct.pluck(:tradition).compact.sort
    @facet_types      = Work.distinct.pluck(:work_type).compact.sort
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
