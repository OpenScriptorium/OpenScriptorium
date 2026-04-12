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
  get "appeal-to-scholars",   to: "about#appeal_to_scholars",   as: :appeal_to_scholars
  get "appeal-to-publishers", to: "about#appeal_to_publishers", as: :appeal_to_publishers

  # Reader. Designed so the URL itself is the OSIS-style human-readable
  # citation: /:work_slug/:book_slug/:chapter[/:verse]
  #
  # work_slug + book_slug pair lets users go directly to a passage in
  # any translation; the chapter/verse segments are required to keep
  # the controller simple. /works gives a directory of every work.
  resources :works, only: [:index, :show], param: :slug
  # "Not in corpus" page for cross-references to works we haven't imported
  get "not-in-corpus/:slug", to: "works#not_in_corpus", as: :not_in_corpus

  # Parallel reader. URL grammar matches the single-work reader so a
  # passage citation looks the same regardless of which view it lands in.
  # Defined before the /:work_slug scope so "parallel" isn't swallowed.
  #
  #   /parallel/:book_slug/:chapter                    — whole chapter
  #   /parallel/:book_slug/:chapter/:verse             — single verse
  #   /parallel/:book_slug/:chapter/:from-:to          — intra-chapter range
  #   /parallel/:book_slug/:from_ch.:from_v-:to_ch.:to_v — cross-chapter range
  get "/parallel/:book_slug/:from_ch.:from_v-:to_ch.:to_v",
      to: "parallel#show",
      as: :parallel_cross_range,
      constraints: { from_ch: /\d+/, from_v: /\d+/, to_ch: /\d+/, to_v: /\d+/ }
  get "/parallel/:book_slug/:chapter/:from-:to",
      to: "parallel#show",
      as: :parallel_range,
      constraints: { chapter: /\d+/, from: /\d+/, to: /\d+/ }
  get "/parallel/:book_slug/:chapter/:verse",
      to: "parallel#show",
      as: :parallel_verse,
      constraints: { chapter: /\d+/, verse: /\d+/ }
  get "/parallel/:book_slug/:chapter",
      to: "parallel#show",
      as: :parallel_chapter,
      constraints: { chapter: /\d+/ }

  # Talmud daf view: /bavli/berakhot/2a
  # Constraint matches daf+amud (e.g. "2a", "63b") — must come before
  # the generic /:work_slug scope so it isn't swallowed as a book_slug.
  scope "/:work_slug" do
    get "/:book_slug/:daf", to: "daf#show", as: :daf,
        constraints: { daf: /\d+[ab]/ }
  end

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

  # Downloads / API documentation
  get "downloads", to: "about#downloads", as: :downloads

  # GNU LibreJS web labels
  get "jslicense", to: "about#jslicense", as: :jslicense

  # JSON API
  namespace :api do
    namespace :v1 do
      resources :works, only: [:index, :show], param: :slug
      get "works/:work_slug/:book_slug/:chapter/:verse", to: "verses#show",
          constraints: { chapter: /\d+/, verse: /\d+/ }
      get "works/:work_slug/:book_slug/:chapter", to: "verses#show",
          constraints: { chapter: /\d+/ }
      get "cross-references", to: "cross_references#index"
      get "search", to: "search#index"
    end
  end

  # Defines the root path route ("/")
  root "home#index"
end
