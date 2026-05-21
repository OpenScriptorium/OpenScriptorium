class StrongsController < ApplicationController
  allow_unauthenticated_access only: [:show]

  # /strongs/:number — Strong's-to-lemma resolver. Accepts:
  #   /strongs/H7225  → resolves to רֵאשִׁית
  #   /strongs/G26    → resolves to ἀγάπη
  #   /strongs/26     → resolves to whichever language matches first
  #
  # Strong's numbers in the corpus are stored inconsistently (some with
  # H/G prefix, some without; sometimes with trailing zeros — see the
  # data-cleanup task). The resolver therefore matches multiple forms
  # of the same number when looking up. If multiple lemmas share a
  # number (homographs), we redirect to the highest-frequency one;
  # alternates are linked as related lemmas on that page.
  def show
    raw = params[:number].to_s.strip
    @canonical = canonicalize(raw) or return not_found

    candidate_forms = forms_for(@canonical)

    lemma_ids = Word
      .where(strongs_number: candidate_forms)
      .where.not(lemma_id: nil)
      .distinct
      .pluck(:lemma_id)

    return not_found if lemma_ids.empty?

    lemma = Lemma.where(id: lemma_ids).order(frequency: :desc).first
    return not_found unless lemma

    redirect_to lemma_path(lemma), status: :found
  end

  private

  # Take whatever the user typed and produce a canonical {prefix:, num:}.
  # Returns nil if the input doesn't look like a Strong's number.
  def canonicalize(raw)
    return nil if raw.blank?
    if (m = raw.match(/\A([HGhg])?(\d+)\z/))
      prefix = m[1]&.upcase
      num = m[2].to_i
      return nil if num <= 0 || num > 99999
      { prefix: prefix, num: num }
    end
  end

  # All plausible storage forms for a given canonical number. Strong's in
  # the corpus may be stored as bare integer ("7225"), prefixed ("H7225"),
  # zero-padded ("H07225"), or with trailing zeros ("G33700"). Match all.
  def forms_for(canonical)
    num = canonical[:num]
    bare = num.to_s
    forms = [bare]
    [4, 5].each { |w| forms << bare.rjust(w, "0") }
    if canonical[:prefix]
      [bare, *[4, 5].map { |w| bare.rjust(w, "0") }].each do |s|
        forms << "#{canonical[:prefix]}#{s}"
      end
    else
      %w[H G].each do |p|
        [bare, *[4, 5].map { |w| bare.rjust(w, "0") }].each do |s|
          forms << "#{p}#{s}"
        end
      end
    end
    # Trailing-zero variants (e.g. G33700 for G3370) — common enough in
    # the data to be worth checking. Cap at one extra zero to avoid
    # exploding the search space.
    forms += forms.map { |f| "#{f}0" }
    forms.uniq
  end

  def not_found
    raise ActiveRecord::RecordNotFound, "Strong's #{params[:number]} not found"
  end
end
