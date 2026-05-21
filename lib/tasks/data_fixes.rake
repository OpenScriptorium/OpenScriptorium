namespace :data do
  # One-off corrective task. Background:
  #
  #   The KJV-strongs importer's `ensure_lemma` looks up Strong's by
  #   exact-string match (`Word.where(strongs_number: "G337")`). The
  #   corpus stores Strong's in incompatible shapes — Patriarchal
  #   stores "G0337" (zero-padded), BSB/RP store bare "337", KJV
  #   passes through "G337". None match "G337" verbatim, so the
  #   importer fell through to a StepLexicon lookup that returned the
  #   wrong entry for "G337" — pointing it at lemma 17622 (Μῆδος)
  #   instead of the ἀναιρέω family. That mis-attached 21 KJV words
  #   ("slay", "kill", "slain"…) to Μῆδος, polluting that lemma's
  #   Strong's display and concordance.
  #
  #   Fix runs surgically against this one known mismatch. The
  #   importer code fix that prevents this in future re-runs lives in
  #   KjvStrongsImporter#ensure_lemma. For broader sweeps detecting
  #   other (Strong's, lemma_id) outliers across the corpus, write a
  #   separate audit task.
  desc "Backfill KJV's 21 G337 lemma_ids that point to Μῆδος → ἀναιρέω cohort"
  task fix_kjv_g337: :environment do
    kjv = Work.find_by!(slug: "kjv")
    medos_id = Lemma.find_by(lemma: "Μῆδος")&.id
    abort "Μῆδος lemma not found" unless medos_id

    # Pick the consensus lemma the rest of the corpus uses for G337.
    # Includes prefix and bare and zero-padded variants the corpus uses.
    cohort_strongs = %w[G337 G0337 337 0337 00337]
    cohort_lemma_id = Word
      .where(strongs_number: cohort_strongs)
      .where.not(work_id: kjv.id)
      .where.not(lemma_id: nil)
      .where.not(lemma_id: medos_id)
      .group(:lemma_id)
      .count
      .max_by { |_, n| n }
      &.first

    abort "No consensus G337 lemma found in non-KJV works" unless cohort_lemma_id
    target = Lemma.find(cohort_lemma_id)
    puts "Target lemma: id=#{target.id} lemma=#{target.lemma} pos=#{target.part_of_speech}"

    n = Word.where(work_id: kjv.id, strongs_number: "G337", lemma_id: medos_id).count
    puts "Updating #{n} KJV words: G337 / lemma_id=#{medos_id} (Μῆδος) → lemma_id=#{target.id} (#{target.lemma})"

    if ENV["DRY_RUN"] == "true"
      puts "(DRY_RUN — no rows updated)"
    else
      updated = Word.where(work_id: kjv.id, strongs_number: "G337", lemma_id: medos_id)
                    .update_all(lemma_id: target.id, updated_at: Time.current)
      puts "Updated #{updated} rows."
    end
  end
end
