module Admin
  class BaseController < ApplicationController
    before_action :require_admin

    private

    def require_admin
      raise ActionController::RoutingError, "Not Found" unless Current.user&.admin?
    end
  end
end
