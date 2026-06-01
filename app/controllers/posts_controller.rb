class PostsController < ApplicationController
  allow_unauthenticated_access only: %i[index show]

  def index
    @posts = Post.published.recent
  end

  def show
    @post = Post.published.find_by!(slug: params[:slug])
  end
end
