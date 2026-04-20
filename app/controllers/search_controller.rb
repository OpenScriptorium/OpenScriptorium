class SearchController < ApplicationController
  allow_unauthenticated_access

  SECTION_LABELS = {
    "ot" => "Hebrew Bible",
    "nt" => "Greek NT",
    "deuterocanon" => "Deuterocanon",
    "pseudepigrapha" => "Pseudepigrapha",
    "apostolic_father" => "Apostolic Fathers",
    "rabbinic" => "Rabbinic",
    "patristic" => "Patristic",
    "other" => "Other"
  }.freeze

  SECTION_BADGES = {
    "ot" => "HB", "nt" => "NT", "deuterocanon" => "DC",
    "pseudepigrapha" => "PS", "apostolic_father" => "AF",
    "rabbinic" => "RAB", "patristic" => "PAT", "other" => "OTH"
  }.freeze

  # GET /search?q=...&work=...&section=...&tradition=...&page=1
  def show
    @query = params[:q].to_s.strip
    @sections = Array(params[:section]).select(&:present?)
    @traditions = Array(params[:tradition]).select(&:present?)
    @active_work = params[:work].presence
    @active_book = params[:book].presence
    @active_features = Array(params[:features]).select(&:present?)
    @drawer_open = params[:filters] == "open" || @sections.any? || @traditions.any? || @active_work || @active_book || @active_features.any?

    # Data for filter drawer
    @available_sections = CanonicalWork::TESTAMENTS.map { |t| [t, SECTION_LABELS[t], SECTION_BADGES[t]] }.reject { |t, _, _| t == "other" }
    @available_traditions = Work.pluck(:traditions).flatten.compact.uniq.sort_by { |t|
      case t
      when "academic" then [0, 0]
      when "ש"  then [1, 0]
      when /\Aש-/ then [1, 1, t]
      when "χ"  then [2, 0]
      when /\Aχ-/ then [2, 1, t]
      else [3, 0, t]
      end
    }
    @available_works = Work.order(:title).pluck(:slug, :title, :language)

    return render :show if @query.blank?

    scope = build_scope

    @result = Search::Executor.new(
      @query,
      scope: scope.presence,
      page: params[:page],
      per_page: params[:per_page] || 25
    ).call

    if @result.redirect?
      redirect_to @result.redirect, allow_other_host: false
      return
    end

    @group_by = params[:group].presence || "reference"
  end

  # GET /search/completions?q=... (JSON for type-ahead)
  def completions
    q = params[:q].to_s.strip
    return render json: [] if q.length < 2

    results = []
    safe_q = ApplicationRecord.sanitize_sql_like(q)

    # Search canonical works (books)
    CanonicalWork.where("title ILIKE ? OR sbl_abbreviation ILIKE ?", "%#{safe_q}%", "%#{safe_q}%")
                 .order(:position)
                 .limit(5)
                 .each { |cw| results << { type: "book", slug: cw.slug, label: cw.title, badge: SECTION_BADGES[cw.testament] } }

    # Search works
    Work.where("title ILIKE ? OR slug ILIKE ?", "%#{safe_q}%", "%#{safe_q}%")
        .order(:title)
        .limit(5)
        .each { |w| results << { type: "work", slug: w.slug, label: "#{w.title} (#{w.language})", badge: w.work_type_label } }

    # Search authors
    Author.where("name ILIKE ? OR latin_name ILIKE ?", "%#{safe_q}%", "%#{safe_q}%")
          .order(:name)
          .limit(3)
          .each { |a| results << { type: "author", slug: a.id.to_s, label: a.name, badge: "author" } } rescue nil

    # Lemma transliteration suggestions — type "aga" → see ἀγάπη (love)
    # Strip diacritics so "agape" matches "agapē"
    if q.match?(/\A[a-zA-Z]/)
      Lemma.where("TRANSLATE(transliteration, 'āēīōūâêîôûḥśšṭṣḍḡṯḇḵ', 'aeiouaeiouhsststdgtbk') ILIKE ?", "#{safe_q}%")
           .where("frequency > 0")
           .where.not(primary_gloss: [nil, ""])
           .order(Arel.sql("frequency DESC"))
           .limit(6)
           .each do |l|
        lang = case l.language
               when "hbo", "he", "arc" then "Hebrew"
               when "grc", "el-koine" then "Greek"
               else l.language
               end
        gloss = l.primary_gloss&.split(";")&.first&.strip&.truncate(30)
        results << {
          type: "lemma",
          label: "#{l.lemma} (#{l.transliteration})",
          detail: "#{gloss} — #{lang}",
          query: "lemma:#{l.lemma}",
          badge: lang == "Hebrew" ? "HE" : "GR"
        }
      end
    end

    # Passage alias suggestions — type "prodig" → see "Prodigal Son"
    if q.length >= 3
      PassageAliasName.where("name ILIKE ?", "%#{safe_q}%")
                      .includes(:passage_alias)
                      .limit(5)
                      .each do |pan|
        results << {
          type: "alias",
          label: pan.name,
          detail: pan.passage_alias.ref,
          query: pan.name,
          badge: "passage"
        }
      end rescue nil
    end

    render json: results
  end

  private

  def build_scope
    scope = {}
    scope[:work] = @active_work if @active_work
    scope[:book] = @active_book if @active_book
    scope[:sections] = @sections if @sections.any?
    scope[:traditions] = @traditions if @traditions.any?
    scope[:work_types] = params[:work_types].presence
    scope[:language] = params[:language].presence
    scope[:features] = @active_features if @active_features.any?
    scope[:mode] = params[:mode].presence  # "hybrid" (default) or "keyword"
    scope.compact
  end

  # Helper to preserve current filter params across links
  helper_method :search_params
  def search_params(overrides = {})
    base = {
      q: @query, group: @group_by, work: @active_work, book: @active_book,
      section: @sections, tradition: @traditions, features: @active_features,
      work_types: params[:work_types], language: params[:language]
    }.compact
    base.merge(overrides).reject { |_, v| v.blank? || (v.is_a?(Array) && v.empty?) }
  end
end
