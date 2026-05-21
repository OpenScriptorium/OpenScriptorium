namespace :lemmas do
  desc "Split Hebrew/Greek lemmas that absorb distinct Strong's onto one headword (e.g. נֵר 'lamp' H5216 and 'Ner' H5369). Requires the drop-unique-index migration to have run."
  task split_homonyms: :environment do
    # We allow same-headword duplicates now (the unique index was
    # dropped). For each lemma whose bound Words carry ≥2 canonical
    # Strong's separated by Δ>20 (the threshold we used to flag
    # homonyms in the integrity audit), create a sibling lemma row
    # per distinct Strong's and rebind Words accordingly.
    DELTA = 20

    candidate_sql = <<~SQL
      WITH lemma_strongs AS (
        SELECT wd.lemma_id, l.language,
          CASE
            WHEN wd.strongs_number ~ '^[HG]\\d+' THEN regexp_replace(wd.strongs_number, '^([HG])0*(\\d+).*$', '\\1\\2')
            WHEN wd.strongs_number ~ '^\\d+$' AND l.language IN ('he','arc','hbo') THEN 'H' || (wd.strongs_number::int)::text
            WHEN wd.strongs_number ~ '^\\d+$' AND l.language IN ('el','el-koine','grc') THEN 'G' || (wd.strongs_number::int)::text
            ELSE NULL END AS canon
        FROM words wd JOIN lemmas l ON l.id = wd.lemma_id
        WHERE wd.strongs_number IS NOT NULL AND wd.strongs_number <> '' AND wd.strongs_number NOT LIKE '%,%'
      ), bucketed AS (
        SELECT lemma_id, MIN(SUBSTRING(canon FROM 2)::int) AS lo, MAX(SUBSTRING(canon FROM 2)::int) AS hi
        FROM lemma_strongs WHERE canon IS NOT NULL GROUP BY lemma_id HAVING COUNT(DISTINCT canon) >= 2
      )
      SELECT lemma_id FROM bucketed WHERE hi - lo > #{DELTA};
    SQL
    ids = ActiveRecord::Base.connection.exec_query(candidate_sql).map { |r| r["lemma_id"] }
    puts "Homonym candidates: #{ids.size}"

    splits_made = 0
    words_rebound = 0
    ids.each do |orig_id|
      orig = Lemma.find(orig_id)

      # Find each distinct canonical Strong's among bound Words.
      groups = ActiveRecord::Base.connection.exec_query(<<~SQL).to_a
        SELECT
          CASE
            WHEN strongs_number ~ '^[HG]\\d+' THEN regexp_replace(strongs_number, '^([HG])0*(\\d+).*$', '\\1\\2')
            ELSE '#{orig.language.in?(%w[he arc hbo]) ? "H" : "G"}' || (strongs_number::int)::text
          END AS canon,
          COUNT(*) AS n
        FROM words WHERE lemma_id = #{orig_id}
          AND strongs_number IS NOT NULL AND strongs_number <> ''
          AND strongs_number NOT LIKE '%,%' AND strongs_number ~ '^[HG0-9]'
        GROUP BY canon ORDER BY n DESC;
      SQL
      next if groups.size < 2

      # The dominant Strong's keeps the original lemma row. Other
      # Strong's get a fresh sibling row.
      dom_canon = groups.first["canon"]
      groups.drop(1).each do |g|
        canon = g["canon"]
        # Create a sibling lemma with the same headword text but no
        # carry-over metadata (a fresh row that will be backfilled by
        # the next gloss/translit/POS passes). normalized stays the
        # same — they ARE spelled the same.
        sibling = Lemma.create!(
          language: orig.language,
          lemma: orig.lemma,
          normalized: orig.normalized,
          frequency: 0
        )
        splits_made += 1

        # Move Words whose canonical Strong's matches this group.
        raw_pattern = canon # e.g. H1120
        bare_num = canon.sub(/\A[HG]/, "")
        prefix = canon[0]
        candidate_strongs = [canon, bare_num,
                             "#{prefix}0#{bare_num}", "#{prefix}00#{bare_num}"].uniq
        moved = Word.where(lemma_id: orig_id, strongs_number: candidate_strongs)
                    .update_all(lemma_id: sibling.id, updated_at: Time.current)
        words_rebound += moved
      end

      puts "  ##{orig_id} #{orig.lemma} (#{orig.primary_gloss.to_s[0..30]}): kept #{dom_canon}, split out #{groups.size - 1} sibling(s)"
    end

    puts
    puts "Sibling lemmas created: #{splits_made}"
    puts "Words rebound to siblings: #{words_rebound}"
  end
end
