class WorksController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]

  def index
    @works = Work.includes(:license).order(:title)
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
