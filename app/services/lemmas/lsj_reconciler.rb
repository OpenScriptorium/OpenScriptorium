module Lemmas
  # Walks existing el-koine Lemma rows, finds matching LSJ LexiconEntries
  # by exact NFC headword, and reconciles:
  #
  #   - Populates Lemma.primary_gloss (only if currently nil)
  #   - Populates Lemma.lexicon_entry_id back-link
  #   - Populates Lemma.homonym_n + Lemma.lsj_key
  #   - For headwords with multiple LSJ entries, creates additional
  #     Lemma rows (one per homonym beyond the first) and re-points
  #     each LexiconEntry.lemma_id at its corresponding homonym Lemma.
  #
  # The first existing Lemma for a headword (lowest id) becomes
  # homonym_n=1. Subsequent homonyms get new Lemma rows.
  #
  # Idempotent: re-running reuses existing homonym rows by (headword,
  # homonym_n) and is a no-op when nothing has changed.
  class LsjReconciler < Importers::BaseImporter
    LSJ_SOURCE = "LSJ".freeze

    def source_url    = "https://github.com/PerseusDL/lexica"
    def source_format = "internal-reconciliation"
    def transactional? = false  # per-headword commits

    def perform
      headwords = Lemma.where(language: "el-koine")
                       .where.not(lemma: nil)
                       .distinct
                       .pluck(:lemma)
      headwords.each do |headword|
        ActiveRecord::Base.transaction { reconcile_headword(headword) }
      end
    end

    private

    def reconcile_headword(headword)
      lsj_entries = LexiconEntry.where(source: LSJ_SOURCE, headword: headword).to_a

      if lsj_entries.empty?
        # Fallback: try morphological variants. Koine deponents and
        # plural adjectives are stored under their active/singular
        # form in LSJ. We don't repoint LexiconEntries here (the LSJ
        # entry's headword belongs to its actual form) — just enrich
        # the Lemma's gloss and lexicon_entry_id pointer.
        if (fallback = fallback_match(headword))
          fallback_enrich(headword, fallback)
        else
          bump(:headwords_no_lsj_match)
        end
        return
      end

      sorted_entries = sort_by_homonym(lsj_entries)

      # Existing Lemma rows for this headword, oldest first (= our
      # "primary" choice for homonym_n = 1).
      lemmas = Lemma.where(language: "el-koine", lemma: headword).order(:id).to_a

      if lemmas.empty?
        # Headword pluck guarantees at least one row exists, but stay
        # defensive: if a race deleted it, just skip.
        bump(:headwords_skipped_no_lemma)
        return
      end

      sorted_entries.each_with_index do |entry, idx|
        homonym_n = idx + 1
        target = lemmas[idx] || build_homonym_lemma(headword)
        apply(target, entry, homonym_n)
      end

      # If we had MORE existing Lemmas than LSJ entries (rare — would
      # mean someone created homonym rows by hand and LSJ doesn't know
      # about them), leave the surplus alone. Log it.
      if lemmas.size > sorted_entries.size
        bump(:lemmas_unreconciled_extra, lemmas.size - sorted_entries.size)
      end

      bump(:headwords_reconciled)
    end

    # Sort LSJ entries by the homonym number embedded in meta["key"].
    # Entries without a numeric suffix (the common solo-entry case)
    # sort first.
    def sort_by_homonym(entries)
      entries.sort_by do |e|
        key = e.meta.is_a?(Hash) ? e.meta["key"].to_s : ""
        _, n = BetaCode.decode(key)
        [n || 0, e.id]
      end
    end

    def build_homonym_lemma(headword)
      Lemma.new(
        language:   "el-koine",
        lemma:      headword,
        normalized: strip_diacritics(headword)
      )
    end

    # Wire one Lemma row to one LSJ LexiconEntry. Updates only the
    # fields that this reconciliation owns; never overwrites an
    # existing primary_gloss.
    def apply(lemma, entry, homonym_n)
      lemma.homonym_n        = homonym_n
      lemma.lsj_key          = entry.meta.is_a?(Hash) ? entry.meta["key"] : nil
      lemma.lexicon_entry_id = entry.id
      lemma.primary_gloss    = entry.summary_gloss if lemma.primary_gloss.blank? && entry.summary_gloss.present?

      if lemma.new_record?
        stamp(lemma)
        lemma.save!
        bump(:lemmas_homonym_created)
      elsif lemma.changed?
        # Don't stamp updates — preserve the original import_run_id
        # so we keep creation provenance. PaperTrail records the
        # field-level diff for the reconciliation event.
        lemma.save!
        bump(:lemmas_updated)
      else
        bump(:lemmas_unchanged)
      end

      # Re-point the LSJ entry's lemma_id at the homonym Lemma it
      # actually corresponds to.
      if entry.lemma_id != lemma.id
        entry.update_columns(lemma_id: lemma.id, updated_at: Time.current)
        bump(:lexicon_entries_relinked)
      end
    end

    def strip_diacritics(s)
      s.to_s.unicode_normalize(:nfd).gsub(/[\p{Mn}]/, "").unicode_normalize(:nfc).downcase
    end

    # Try morphological variants of the headword against LSJ. Returns
    # the first LexiconEntry found via any fallback, or nil.
    def fallback_match(headword)
      fallback_forms(headword).each do |alt|
        next if alt == headword
        entry = LexiconEntry.where(source: LSJ_SOURCE, headword: alt).first
        return entry if entry
      end
      nil
    end

    # Common Koine-vs-Classical headword transforms:
    #   ομαι  → ω      (deponent middle to active citation form)
    #   οι    → ος     (masc plural adj to masc sg)
    #   αι    → η      (1st-decl fem plural to fem sg)
    def fallback_forms(headword)
      forms = []
      forms << headword.sub(/ομαι\z/, "ω")  if headword.end_with?("ομαι")
      forms << headword.sub(/οι\z/, "ος")   if headword.end_with?("οι")
      forms << headword.sub(/αι\z/, "η")    if headword.end_with?("αι")
      forms
    end

    # Enrich the existing Lemma row using a fallback-matched LSJ entry.
    # We populate primary_gloss + lexicon_entry_id but NOT homonym_n or
    # lsj_key — those would misrepresent the actual LSJ key, since the
    # match went through a different headword form.
    def fallback_enrich(headword, entry)
      lemma = Lemma.where(language: "el-koine", lemma: headword).order(:id).first
      return unless lemma

      changed = false
      if lemma.primary_gloss.blank? && entry.summary_gloss.present?
        lemma.primary_gloss = entry.summary_gloss
        changed = true
      end
      if lemma.lexicon_entry_id.nil?
        lemma.lexicon_entry_id = entry.id
        changed = true
      end

      if changed
        lemma.save!
        bump(:lemmas_glossed_via_fallback)
      else
        bump(:lemmas_unchanged)
      end
    end
  end
end
