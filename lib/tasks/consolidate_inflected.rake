namespace :lemmas do
  desc "Consolidate inflected lemma rows into their dictionary forms. DRY_RUN=1 to preview."
  task consolidate_inflected: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    conn = ActiveRecord::Base.connection

    inflected = Lemma.where.not(canonical_lemma_id: nil)
                     .pluck(:id, :canonical_lemma_id)
                     .to_h
    if inflected.empty?
      puts "No inflected lemmas remain. Nothing to do."
      next
    end
    puts "Inflected lemmas: #{inflected.size}"

    # Resolve TERMINAL canonical for each inflected lemma. The audit
    # showed 187 depth-2 chains and 21 depth-3+ chains, so a single
    # canonical_lemma_id step is not enough — walk to the first lemma
    # whose canonical_lemma_id is NULL.
    terminal_for = {}
    broken = []
    inflected.each do |id, parent|
      seen = Set[id]
      cur  = parent
      while cur && inflected[cur] && !seen.include?(cur)
        seen << cur
        cur = inflected[cur]
      end
      # cur exits as either nil (chain dangles), already-in-seen (cycle),
      # or a non-inflected lemma id (terminal canonical).
      if cur.nil? || seen.include?(cur)
        broken << id
      else
        terminal_for[id] = cur
      end
    end
    puts "Resolved terminals:    #{terminal_for.size}"
    puts "Broken chains skipped: #{broken.size}" if broken.any?

    # Field promotion: where the dictionary canonical lacks data the
    # inflected row has. Only fills gaps; never overwrites canonical data.
    promote_fields = %i[transliteration primary_gloss part_of_speech etymology]
    promoted = Hash.new(0)
    families  = terminal_for.group_by { |_, t| t }.transform_values { |arr| arr.map(&:first) }
    puts "Distinct terminal canonicals: #{families.size}"

    families.each do |canonical_id, member_ids|
      canonical = Lemma.find(canonical_id)
      member_rows = Lemma.where(id: member_ids).to_a
      changes = {}
      member_rows.each do |inf|
        promote_fields.each do |f|
          if canonical[f].blank? && inf[f].present? && !changes.key?(f)
            changes[f] = inf[f]
            promoted[f] += 1
          end
        end
      end
      next if changes.empty?
      changes.each { |f, v| canonical[f] = v }
      canonical.save! unless dry_run
    end
    puts "Fields promoted:       #{promoted.inspect}"

    # Bulk remap via temp table — single indexed UPDATE for all 950k+ words.
    conn.execute("DROP TABLE IF EXISTS tmp_lemma_consolidation")
    conn.execute(<<~SQL)
      CREATE TEMP TABLE tmp_lemma_consolidation (
        old_id bigint PRIMARY KEY,
        new_id bigint NOT NULL
      )
    SQL
    terminal_for.each_slice(2000) do |chunk|
      values = chunk.map { |old, new_| "(#{old}, #{new_})" }.join(",")
      conn.execute("INSERT INTO tmp_lemma_consolidation VALUES #{values}") unless values.empty?
    end

    expected_words = conn.select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM words w
        JOIN tmp_lemma_consolidation m ON w.lemma_id = m.old_id
    SQL
    expected_lex = conn.select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM lexicon_entries le
        JOIN tmp_lemma_consolidation m ON le.lemma_id = m.old_id
    SQL
    puts "Words to remap:        #{expected_words}"
    puts "LexiconEntries remap:  #{expected_lex}"

    if dry_run
      puts ""
      puts "[dry-run] no writes performed."
      conn.execute("DROP TABLE IF EXISTS tmp_lemma_consolidation")
      next
    end

    # Single transaction for the destructive phase. If any step fails,
    # rolls back to a sane state — words and lemmas stay consistent.
    n_words = n_lex = n_deleted = 0
    ActiveRecord::Base.transaction do
      n_words = conn.update(<<~SQL)
        UPDATE words w SET lemma_id = m.new_id, updated_at = NOW()
          FROM tmp_lemma_consolidation m
         WHERE w.lemma_id = m.old_id
      SQL
      n_lex = conn.update(<<~SQL)
        UPDATE lexicon_entries le SET lemma_id = m.new_id, updated_at = NOW()
          FROM tmp_lemma_consolidation m
         WHERE le.lemma_id = m.old_id
      SQL

      # Null out canonical_lemma_id on the rows we're about to delete.
      # The self-FK has no ON DELETE CASCADE; without this step, deleting
      # a depth-1 inflected lemma fails when a depth-2 inflected lemma
      # still points at it (both are in the delete set, but Postgres
      # checks the FK row-by-row within the statement).
      conn.update(<<~SQL)
        UPDATE lemmas SET canonical_lemma_id = NULL, updated_at = NOW()
         WHERE id IN (SELECT old_id FROM tmp_lemma_consolidation)
      SQL

      n_deleted = conn.delete(<<~SQL)
        DELETE FROM lemmas
         WHERE id IN (SELECT old_id FROM tmp_lemma_consolidation)
      SQL
    end

    conn.execute("DROP TABLE IF EXISTS tmp_lemma_consolidation")

    puts ""
    puts "Words remapped:        #{n_words}"
    puts "LexiconEntries remap:  #{n_lex}"
    puts "Lemmas deleted:        #{n_deleted}"

    remaining = Lemma.where.not(canonical_lemma_id: nil).count
    puts ""
    puts "Inflected lemmas remaining: #{remaining}"
  end
end
