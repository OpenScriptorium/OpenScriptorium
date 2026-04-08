Rails.application.routes.draw do
  # Auth
  resource :session
  resources :passwords, param: :token

  # Reveal health status on /up that returns 200 if the app boots with no
  # exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Architecture / about pages
  get "about/architecture",  to: "about#architecture",        as: :about_architecture
  get "about/schema",        to: "about#schema",              as: :about_schema
  get "principles",          to: "about#principles",          as: :principles
  get "appeal-to-scholars",  to: "about#appeal_to_scholars",  as: :appeal_to_scholars

  # Reader. Designed so the URL itself is the OSIS-style human-readable
  # citation: /:work_slug/:book_slug/:chapter[/:verse]
  #
  # work_slug + book_slug pair lets users go directly to a passage in
  # any translation; the chapter/verse segments are required to keep
  # the controller simple. /works gives a directory of every work.
  resources :works, only: [:index, :show], param: :slug

  scope "/:work_slug" do
    get "/:book_slug",                  to: "reader#book",    as: :reader_book

    # Cross-chapter range: /bsb/genesis/1.1-2.3
    # Constraint comes first so it's matched before the bare chapter route.
    get "/:book_slug/:from_ch.:from_v-:to_ch.:to_v",
        to: "reader#cross_chapter_range",
        as: :reader_cross_range,
        constraints: { from_ch: /\d+/, from_v: /\d+/, to_ch: /\d+/, to_v: /\d+/ }

    # Intra-chapter range: /bsb/genesis/1/1-5
    get "/:book_slug/:chapter/:from-:to",
        to: "reader#range",
        as: :reader_range,
        constraints: { chapter: /\d+/, from: /\d+/, to: /\d+/ }

    # Single verse: /bsb/genesis/1/1
    get "/:book_slug/:chapter/:verse",  to: "reader#verse",   as: :reader_verse,
                                        constraints: { chapter: /\d+/, verse: /\d+/ }

    # Whole chapter: /bsb/genesis/1
    get "/:book_slug/:chapter",         to: "reader#chapter", as: :reader_chapter,
                                        constraints: { chapter: /\d+/ }
  end

  # Defines the root path route ("/")
  root "home#index"
end
