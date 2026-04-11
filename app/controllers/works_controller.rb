class WorksController < ApplicationController
  allow_unauthenticated_access only: [:index, :show, :not_in_corpus]

  def index
    # Selected filters come from URL params and seed the form's
    # initial state. The actual filtering happens client-side in the
    # works-filter Stimulus controller — for ~10 works this is far
    # snappier than a server roundtrip on every input change, and
    # avoids re-running the per-work feature predicates (which each
    # cost an indexed query and add up under heavy import write
    # contention).
    @selected_features   = Array(params[:features]).select { |f| Work::FEATURE_DEFINITIONS.any? { |d| d[0] == f } }
    @selected_languages  = Array(params[:languages]).select(&:present?)
    @selected_traditions = Array(params[:traditions]).select(&:present?)
    @selected_types      = Array(params[:types]).select(&:present?)

    @works = Work.includes(:license).order(:title).to_a

    @facet_languages  = @works.map(&:language).compact.uniq.sort
    # Sort traditions: academic first, then Jewish, then Christian
    @facet_traditions = @works.flat_map(&:traditions).compact.uniq.sort_by { |t|
      case t
      when "academic" then [0, 0]
      when "ש"  then [1, 0]
      when /\Aש-/ then [1, 1, t]
      when "χ"  then [2, 0]
      when /\Aχ-/ then [2, 1, t]
      else [3, 0, t]
      end
    }
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

  # Cross-reference target whose text hasn't been imported yet.
  # Linked from xref helpers when resolve_work_for_canonical_work
  # returns nil.
  def not_in_corpus
    @canonical_work = CanonicalWork.find_by(slug: params[:slug])
    # Fall back to treating the slug as a display name
    @title = @canonical_work&.title || params[:slug].titleize.gsub("-", " ")
    @description = @canonical_work&.description
  end
end
