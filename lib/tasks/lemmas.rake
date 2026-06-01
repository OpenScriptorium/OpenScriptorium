namespace :lemmas do
  desc "Recompute lemmas.frequency from the words table (drift fix after lemma cleanups / re-binds)"
  task refresh_frequency: :environment do
    conn = ActiveRecord::Base.connection
    puts "Recomputing lemmas.frequency from words..."
    started = Time.now

    # One UPDATE that covers attested lemmas via aggregate join.
    n_attested = conn.update(<<~SQL)
      UPDATE lemmas l
         SET frequency = sub.cnt
        FROM (
          SELECT lemma_id, COUNT(*) AS cnt
            FROM words
           WHERE lemma_id IS NOT NULL
        GROUP BY lemma_id
        ) sub
       WHERE l.id = sub.lemma_id
         AND l.frequency IS DISTINCT FROM sub.cnt
    SQL
    puts "  attested lemmas updated: #{n_attested}"

    # Zero out lemmas with no words attached.
    n_zeroed = conn.update(<<~SQL)
      UPDATE lemmas l
         SET frequency = 0
       WHERE NOT EXISTS (SELECT 1 FROM words w WHERE w.lemma_id = l.id)
         AND l.frequency IS DISTINCT FROM 0
    SQL
    puts "  unattested lemmas zeroed: #{n_zeroed}"

    puts "Done in #{(Time.now - started).round(1)}s"
  end

  desc "Link el-koine Lemma rows to LSJ LexiconEntries by NFC headword. " \
       "Populates primary_gloss (when nil), lexicon_entry_id, homonym_n, lsj_key. " \
       "Creates new Lemma rows for LSJ homonyms beyond the first."
  task reconcile_lsj: :environment do
    Lemmas::LsjReconciler.new.call
  end

  desc "Cross-link unglossed Greek Hebrew-name lemmas (Ααρων, Βαιθλεεμ, …) to " \
       "Hebrew lemmas by canonical_ref overlap. Populates primary_gloss with the " \
       "Hebrew equivalent (e.g. \"Aaron (= אַהֲרֹν)\")."
  task cross_link_hebrew: :environment do
    Lemmas::HebrewCrossLinker.new.call
  end

  desc "Write per-chunk JSON files for unglossed el-koine lemmas, paired with verse " \
       "contexts. Output: /tmp/gloss_chunks/chunk_NNN.json. For editorial review."
  task chunk_residue: :environment do
    stats = Lemmas::ResidueChunker.new.call
    puts stats.inspect
  end

  desc "Apply editorial gloss decisions from /tmp/gloss_chunks/chunk_NNN.glosses.tsv " \
       "back to Lemma rows. Set OVERRIDE=true to replace existing glosses."
  task apply_residue: :environment do
    override = ENV["OVERRIDE"] == "true"
    Lemmas::ResidueApplier.new(override: override).call
  end

  desc "Coverage report: which el-koine Lemmas have a gloss; which don't, by category."
  task gloss_coverage: :environment do
    total = Lemma.where(language: "el-koine").count
    glossed = Lemma.where(language: "el-koine").where.not(primary_gloss: nil).count
    matched = Lemma.where(language: "el-koine").where.not(lexicon_entry_id: nil).count
    unmatched_rows = Lemma.where(language: "el-koine", primary_gloss: nil).pluck(:lemma)
    unmatched = unmatched_rows.size

    puts "=" * 60
    puts "Greek lemma gloss coverage"
    puts "=" * 60
    puts "  Total el-koine lemmas:     #{total.to_s.rjust(6)}"
    puts "  With primary_gloss:        #{glossed.to_s.rjust(6)}  (#{(glossed.to_f/total*100).round(1)}%)"
    puts "  Linked to lexicon entry:   #{matched.to_s.rjust(6)}  (#{(matched.to_f/total*100).round(1)}%)"
    puts "  Without gloss:             #{unmatched.to_s.rjust(6)}  (#{(unmatched.to_f/total*100).round(1)}%)"
    puts ""

    # Categorize the unmatched
    caps    = unmatched_rows.count { |l| l && l[0] =~ /[\p{Lu}]/ }
    deps    = unmatched_rows.count { |l| l&.end_with?("ομαι") }
    plural  = unmatched_rows.count { |l| l && (l.end_with?("οι") || l.end_with?("αι")) }
    short   = unmatched_rows.count { |l| l && l.size <= 2 }
    other   = unmatched - caps - deps - plural - short

    puts "Unmatched breakdown:"
    puts "  Hebrew proper names (capital letter):  #{caps.to_s.rjust(6)}  (#{(caps.to_f/unmatched*100).round(1)}% of unmatched)"
    puts "  Deponent middle (-ομαι):               #{deps.to_s.rjust(6)}"
    puts "  Likely plural (-οι/-αι):               #{plural.to_s.rjust(6)}"
    puts "  ≤2 chars:                              #{short.to_s.rjust(6)}"
    puts "  Other:                                 #{other.to_s.rjust(6)}"
    puts ""

    # Probe how many deponent middles would match LSJ as active form
    dep_sample = unmatched_rows.select { |l| l&.end_with?("ομαι") }.first(200)
    dep_hits = dep_sample.count { |hw| LexiconEntry.where(source: "LSJ", headword: hw.sub(/ομαι\z/, "ω")).exists? }
    puts "Fallback opportunity:"
    puts "  Deponent middle → LSJ active form:     #{dep_hits} of #{dep_sample.size} sampled hit"

    puts ""
    puts "Notes:"
    puts "  * Hebrew indeclinables (~83% of unmatched) cannot be glossed from"
    puts "    a Greek lexicon. Source for these: a separate biblical-name"
    puts "    database (e.g. ISBE, Easton's) or accept unglossed."
    puts "  * Deponent middles match LSJ at roughly an 80% rate when"
    puts "    rewritten as active; cheap to add as a Round-2 fallback."
  end
end
