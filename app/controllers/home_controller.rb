class HomeController < ApplicationController
  allow_unauthenticated_access only: :index

  def index
    @latest_post = Post.published.recent.first
  end
end
