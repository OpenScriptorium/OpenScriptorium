namespace :lemmas do
  desc "Override primary_gloss with STEPBible's value where a lemma has both STEPBible and LSJ entries (STEPBible is curated for biblical Greek; LSJ ships Homeric senses that pollute NT lemmas — e.g. λέγω was showing 'lay' instead of 'to say')"
  task prefer_step_glosses: :environment do
    bad_gloss = ->(s) { s.blank? || s.start_with?("(") }

    sql = <<~SQL
      SELECT l.id, l.lemma, l.primary_gloss,
             (SELECT summary_gloss FROM lexicon_entries WHERE lemma_id = l.id AND source = 'STEPBible' LIMIT 1) AS step_gloss,
             (SELECT summary_gloss FROM lexicon_entries WHERE lemma_id = l.id AND source = 'LSJ' LIMIT 1) AS lsj_gloss
      FROM lemmas l
      WHERE EXISTS (SELECT 1 FROM lexicon_entries WHERE lemma_id = l.id AND source = 'STEPBible')
        AND EXISTS (SELECT 1 FROM lexicon_entries WHERE lemma_id = l.id AND source = 'LSJ')
    SQL

    fixed = 0
    skipped_step_blank = 0
    same = 0
    ActiveRecord::Base.connection.exec_query(sql).each do |row|
      step = row["step_gloss"].to_s.strip
      if bad_gloss.(step)
        skipped_step_blank += 1
        next
      end
      current = row["primary_gloss"].to_s.strip
      if current == step
        same += 1
        next
      end
      # Only override when current looks like an LSJ-Homeric carryover —
      # i.e. it matches the LSJ summary_gloss verbatim. Don't clobber
      # curated edits.
      lsj = row["lsj_gloss"].to_s.strip
      next unless current == lsj || current.empty?
      Lemma.where(id: row["id"]).update_all(primary_gloss: step[0, 200], updated_at: Time.current)
      fixed += 1
    end

    puts "Lemmas with both STEPBible and LSJ entries: examined"
    puts "  primary_gloss overridden to STEPBible's value: #{fixed}"
    puts "  STEPBible gloss blank/parenthetical (skipped): #{skipped_step_blank}"
    puts "  Already matched STEPBible: #{same}"
  end
end
