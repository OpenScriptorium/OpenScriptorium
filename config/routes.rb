Rails.application.routes.draw do
  # Auth
  resource :session
  resources :passwords, param: :token

  # Reveal health status on /up that returns 200 if the app boots with no
  # exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Architecture / about pages
  get "about/architecture", to: "about#architecture", as: :about_architecture
  get "about/schema",       to: "about#schema",       as: :about_schema

  # Reader. Designed so the URL itself is the OSIS-style human-readable
  # citation: /:work_slug/:book_slug/:chapter[/:verse]
  #
  # work_slug + book_slug pair lets users go directly to a passage in
  # any translation; the chapter/verse segments are required to keep
  # the controller simple. /works gives a directory of every work.
  resources :works, only: [:index, :show], param: :slug

  scope "/:work_slug" do
    get "/:book_slug",                  to: "reader#book",    as: :reader_book
    get "/:book_slug/:chapter",         to: "reader#chapter", as: :reader_chapter,
                                        constraints: { chapter: /\d+/ }
    get "/:book_slug/:chapter/:verse",  to: "reader#verse",   as: :reader_verse,
                                        constraints: { chapter: /\d+/, verse: /\d+/ }
  end

  # Defines the root path route ("/")
  root "home#index"
end
