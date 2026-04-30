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
end
