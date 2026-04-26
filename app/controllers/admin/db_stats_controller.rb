module Admin
  # Read-only DB size dashboard. /admin/db_stats
  # Public — not sensitive (it's diagnostic info on the public corpus).
  class DbStatsController < ApplicationController
    allow_unauthenticated_access only: :show

    def show
      @stats = ::Admin::DbStats.fetch
    end
  end
end
