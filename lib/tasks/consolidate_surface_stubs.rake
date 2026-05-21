namespace :lemmas do
  desc "Consolidate surface-form stub lemmas into their dictionary canonical via Strong's. DRY_RUN=1 to preview."
  task consolidate_surface_stubs: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    conn = ActiveRecord::Base.connection

    # Stubs: have words, no metadata of any kind (no gloss, no translit,
    # no POS, no lexicon entries). These escaped phase 3 because they
    # never had canonical_lemma_id set — typically created by BsbTables
    # / RP / CntrSr from a surface form like "αιωνιον" in a corpus that
    # also has the dictionary form "αἰώνιος" with full metadata.
    stubs = Lemma
      .where("EXISTS (SELECT 1 FROM words WHERE words.lemma_id = lemmas.id)")
      .where("NOT EXISTS (SELECT 1 FROM lexicon_entries WHERE lexicon_entries.lemma_id = lemmas.id)")
      .where(primary_gloss: [nil, ""])
      .where(transliteration: [nil, ""])
      .where(part_of_speech: [nil, ""])
      .pluck(:id, :language)
    puts "Surface-form stubs: #{stubs.size}"

    hebrew_family = %w[he arc hbo].freeze
    greek_family  = %w[el el-koine grc].freeze

    family_for = ->(lang) {
      hebrew_family.include?(lang) ? hebrew_family : greek_family.include?(lang) ? greek_family : [lang]
    }

    remap = {}                      # stub_id => canonical_id
    no_canonical = 0
    no_strongs = 0

    stubs.each do |stub_id, lang|
      family = family_for.call(lang)
      # Top Strong's for this stub's words.
      raw_strongs = Word.where(lemma_id: stub_id).where.not(strongs_number: [nil, ""])
                       .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                       .limit(1).pick(:strongs_number)
      unless raw_strongs
        no_strongs += 1
        next
      end

      canon = Strongs.normalize(raw_strongs, language: lang)
      unless canon
        no_strongs += 1
        next
      end
      bare = canon[1..]

      # EXACT Strong's lookup only — never trail-drop here. Trail-drop
      # was added to the importer helper for CNTR ESN compatibility,
      # but for stub-consolidation we must NOT cross-collapse into
      # neighbour Strong's (G166 → G16 would mismerge αἰώνιος → ἁγιάζω).
      lookup_forms = [raw_strongs, canon, bare]
      %w[G H].each do |p|
        %w[ 0 00].each { |pad| lookup_forms << "#{p}#{pad}#{bare}" }
      end
      lookup_forms.uniq!

      candidates = Word.joins(:lemma)
                       .where(strongs_number: lookup_forms)
                       .where("lemmas.language IN (?)", family)
                       .where.not(lemma_id: stub_id)
                       .group(:lemma_id)
                       .count

      # Filter to candidates that HAVE metadata (gloss / translit / POS / lex entry)
      with_meta = Lemma.where(id: candidates.keys)
                       .where(<<~SQL)
                         (primary_gloss IS NOT NULL AND primary_gloss <> '')
                         OR (transliteration IS NOT NULL AND transliteration <> '')
                         OR (part_of_speech IS NOT NULL AND part_of_speech <> '')
                         OR EXISTS (SELECT 1 FROM lexicon_entries le WHERE le.lemma_id = lemmas.id)
                       SQL
                       .pluck(:id)

      if with_meta.empty?
        no_canonical += 1
        next
      end

      # Sanity check: the candidate's OWN top Strong's must normalize to
      # the same canonical as the stub's top Strong's. Without this, a
      # single corpus word with bad strongs storage (e.g. one Ἀβραάμ
      # word miss-tagged "G0112") drags an unrelated lemma into the
      # candidate set and lets it win on the wc tiebreak.
      best = with_meta
        .filter_map do |id|
          c_top = Word.where(lemma_id: id).where.not(strongs_number: [nil, ""])
                     .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                     .limit(1).pick(:strongs_number)
          c_canon = c_top && Strongs.normalize(c_top, language: family.first)
          [id, candidates[id] || 0] if c_canon == canon
        end
        .max_by { |_, n| n }
        &.first

      if best.nil? || best == stub_id
        no_canonical += 1
        next
      end
      remap[stub_id] = best
    end

    puts "Mappable stubs:        #{remap.size}"
    puts "No canonical sibling:  #{no_canonical}"
    puts "No Strong's:           #{no_strongs}"

    if remap.empty?
      puts "Nothing to do."
      next
    end

    # Sample of remaps for visibility
    puts ""
    puts "Sample remaps:"
    remap.first(8).each do |old, new_|
      o = Lemma.find(old)
      n = Lemma.find(new_)
      puts "  #{o.lemma.ljust(20)} (id=#{o.id}, freq=#{o.frequency}) -> #{n.lemma.ljust(20)} (id=#{n.id}, freq=#{n.frequency})"
    end

    if dry_run
      puts ""
      puts "[dry-run] no writes performed."
      next
    end

    # Bulk remap via temp table (same shape as phase 3).
    conn.execute("DROP TABLE IF EXISTS tmp_stub_consolidation")
    conn.execute(<<~SQL)
      CREATE TEMP TABLE tmp_stub_consolidation (
        old_id bigint PRIMARY KEY,
        new_id bigint NOT NULL
      )
    SQL
    remap.each_slice(2000) do |chunk|
      values = chunk.map { |old, new_| "(#{old}, #{new_})" }.join(",")
      conn.execute("INSERT INTO tmp_stub_consolidation VALUES #{values}")
    end

    n_words = n_lex = n_deleted = 0
    ActiveRecord::Base.transaction do
      n_words = conn.update(<<~SQL)
        UPDATE words w SET lemma_id = m.new_id, updated_at = NOW()
          FROM tmp_stub_consolidation m
         WHERE w.lemma_id = m.old_id
      SQL
      n_lex = conn.update(<<~SQL)
        UPDATE lexicon_entries le SET lemma_id = m.new_id, updated_at = NOW()
          FROM tmp_stub_consolidation m
         WHERE le.lemma_id = m.old_id
      SQL
      conn.update(<<~SQL)
        UPDATE lemmas SET canonical_lemma_id = NULL, updated_at = NOW()
         WHERE id IN (SELECT old_id FROM tmp_stub_consolidation)
      SQL
      n_deleted = conn.delete(<<~SQL)
        DELETE FROM lemmas
         WHERE id IN (SELECT old_id FROM tmp_stub_consolidation)
      SQL
    end

    conn.execute("DROP TABLE IF EXISTS tmp_stub_consolidation")

    # Refresh frequencies on the canonical recipients.
    canonical_ids = remap.values.uniq
    canonical_ids.each_slice(1000) do |chunk|
      conn.execute(<<~SQL)
        UPDATE lemmas
        SET frequency = COALESCE(sub.wc, 0)
        FROM (SELECT lemma_id, COUNT(*) AS wc FROM words WHERE lemma_id IN (#{chunk.join(',')}) GROUP BY lemma_id) sub
        WHERE lemmas.id = sub.lemma_id
      SQL
    end

    puts ""
    puts "Words remapped:    #{n_words}"
    puts "LexEntries remap:  #{n_lex}"
    puts "Stubs deleted:     #{n_deleted}"
  end
end
