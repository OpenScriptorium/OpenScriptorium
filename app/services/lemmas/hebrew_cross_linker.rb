module Lemmas
  # Cross-links Greek Hebrew-indeclinable Lemmas (Hebrew proper names
  # transliterated into LXX Greek) to their Hebrew lemma equivalents
  # by canonical_ref overlap.
  #
  # For each Greek Lemma starting with a capital letter (= Hebrew
  # proper-noun transliteration per the lxx-morph convention), we:
  #
  #   1. Find the canonical_refs where the Greek Lemma appears.
  #   2. Find candidate Hebrew Lemmas (capital-glossed proper names)
  #      that appear in any of those same refs.
  #   3. Score each candidate by (px * py) where:
  #        px = |intersect| / |greek_refs|     (recall on Greek side)
  #        py = |intersect| / |hebrew_total|   (specificity on Heb side)
  #   4. Accept the top candidate when score and absolute coverage
  #      exceed thresholds. Reject the match otherwise — high-frequency
  #      names like Israel or Jerusalem don't cross-link reliably this
  #      way and need a different strategy (transliteration or manual).
  #
  # The accepted match's Hebrew gloss becomes the Greek Lemma's
  # primary_gloss.
  class HebrewCrossLinker < Importers::BaseImporter
    # Score thresholds. Conservative — we'd rather miss matches than
    # introduce wrong ones.
    MIN_SCORE     = 0.02   # px * py
    MIN_RECALL_PX = 0.50   # at least half the Greek refs share the Hebrew lemma
    MIN_PRECISION_PY = 0.04  # Hebrew lemma isn't TOO scattered
    DOMINATION_RATIO = 1.5  # top candidate must beat 2nd-best by this factor

    def source_url    = "internal://greek-hebrew-crosslink"
    def source_format = "internal-reconciliation"
    def transactional? = false

    def perform
      # Filter capital-initial names in Ruby — Postgres POSIX regex
      # doesn't accept \p{Lu} for Unicode-aware uppercase matching,
      # and Greek polytonic capitals are scattered across several
      # blocks (basic Greek, polytonic Greek extended).
      candidates = Lemma.where(language: "el-koine", primary_gloss: nil)
                        .pluck(:id, :lemma)
                        .select { |_, hw| hw && hw[0].match?(/\p{Lu}/) }
      Rails.logger.info "[#{self.class.name}] #{candidates.size} candidate Greek names"

      candidates.each do |greek_id, greek_hw|
        ActiveRecord::Base.transaction { try_link(greek_id, greek_hw) }
      end
    end

    private

    def try_link(greek_id, greek_hw)
      greek_refs = Word.joins(:work_unit)
                       .where(lemma_id: greek_id)
                       .distinct
                       .pluck("work_units.canonical_ref_id")
      if greek_refs.empty?
        bump(:skipped_no_refs)
        return
      end
      g_size = greek_refs.size

      ranked = score_candidates(greek_refs, g_size)
      if ranked.empty?
        bump(:skipped_no_hebrew_candidates)
        return
      end

      best = ranked.first
      runner_up = ranked[1]

      reject_reason = reject_match?(best, runner_up, g_size)
      if reject_reason
        bump("rejected_#{reject_reason}".to_sym)
        return
      end

      _heb_id, heb_hw, heb_gloss, _intersect, _total, _score = best

      lemma = Lemma.find(greek_id)
      lemma.primary_gloss = format_gloss(heb_hw, heb_gloss)
      if lemma.changed?
        lemma.save!
        bump(:linked)
      else
        bump(:unchanged)
      end
    end

    # Format the Hebrew gloss as the Greek Lemma's primary_gloss.
    # Keep it short — popovers show 1-2 lines. The Hebrew form goes
    # in parens so the reader can see what we're equating.
    def format_gloss(hebrew_headword, hebrew_gloss)
      "#{hebrew_gloss} (= #{hebrew_headword})"
    end

    # Return a symbol naming the rejection reason, or nil to accept.
    def reject_match?(best, runner_up, g_size)
      _, _, _, intersect, total, score = best
      px = intersect.to_f / g_size       # recall on Greek side
      py = intersect.to_f / total         # specificity on Hebrew side

      return :low_score          if score < MIN_SCORE
      return :low_recall         if px < MIN_RECALL_PX
      return :low_specificity    if py < MIN_PRECISION_PY
      if runner_up && runner_up[5] > 0 && (score / runner_up[5]) < DOMINATION_RATIO
        return :ambiguous_runner_up
      end
      nil
    end

    # Score & rank candidate Hebrew Lemmas for a Greek Lemma's verse
    # appearances.
    def score_candidates(greek_refs, g_size)
      rows = Lemma.where(language: %w[he hbo])
                   .where("primary_gloss ~ ?", "^[A-Z]")
                   .joins(words: :work_unit)
                   .where(work_units: { canonical_ref_id: greek_refs })
                   .group(:id, :lemma, :primary_gloss)
                   .pluck(:id, :lemma, :primary_gloss,
                          Arel.sql("COUNT(DISTINCT work_units.canonical_ref_id)"))
      return [] if rows.empty?

      totals = Word.joins(:work_unit)
                    .where(lemma_id: rows.map(&:first))
                    .group(:lemma_id)
                    .distinct
                    .count("work_units.canonical_ref_id")

      scored = rows.map do |id, hw, en, intersect|
        total = totals[id] || 1
        px = intersect.to_f / g_size
        py = intersect.to_f / total
        score = px * py
        [id, hw, en, intersect, total, score]
      end
      scored.sort_by { |row| -row[5] }
    end
  end
end
