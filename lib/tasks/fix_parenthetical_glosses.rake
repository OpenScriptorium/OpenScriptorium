namespace :lemmas do
  desc "One-shot cleanup of primary_gloss values that start with a place-modifier prefix like '(Gibeath)-elohim' or '(Jerusalem of) the Lord; YHWH/God'"
  task fix_parenthetical_glosses: :environment do
    # Three buckets:
    #   1) "(...) X; real sense"  → keep "real sense" (the post-semicolon tail)
    #   2) "(...) X"              → re-derive from TBESH by lemma's bound Strong's
    #   3) Still unrecoverable    → fall back to stripping the parenthetical
    #                                ("(Gibeath)-elohim" → "elohim")

    affected = Lemma.where("primary_gloss ~ ?", '^\(')
    puts "Lemmas with parenthetical-prefix gloss: #{affected.count}"

    # Build a TBESH/TBESG Strong's → first-good-gloss map for bucket #2.
    DIR = Rails.root.join("tmp/stepbible")
    good_gloss = {}
    parse = ->(path, prefix) {
      File.foreach(path) do |line|
        cols = line.split("\t")
        next if cols.size < 7
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)
        base = ext.match(/\A([HG])(\d+)/)&.then { |m| "#{m[1]}#{m[2].to_i}" }
        next unless base
        g = cols[6].to_s.strip
        next if g.empty? || g.start_with?("(") || g.match?(/\A[A-Z]/)
        good_gloss[base] ||= g
      end
    }
    parse.call(DIR.join("TBESH.txt"), "H")
    parse.call(DIR.join("TBESG.txt"), "G")
    puts "TBESH/TBESG Strong's → common-word gloss entries: #{good_gloss.size}"

    bucket1 = 0
    bucket2 = 0
    bucket3 = 0
    affected.find_each do |l|
      raw = l.primary_gloss.to_s

      # Bucket 1: there's a "; <real sense>" tail.
      tail = raw.split(";", 2).last.to_s.strip
      tail = nil if tail == raw.strip || tail.start_with?("(") || tail.empty?
      if tail
        l.update_columns(primary_gloss: tail)
        bucket1 += 1
        next
      end

      # Bucket 2: re-derive from TBESH using the lemma's dominant Strong's.
      dominant = Word.where(lemma_id: l.id)
                     .where.not(strongs_number: nil)
                     .where("strongs_number !~ ','")
                     .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                     .limit(1).pick(:strongs_number)
      if dominant
        m = dominant.match(/\A([HG]?)(\d+)/i)
        canon = m && (m[1].present? ? "#{m[1].upcase}#{m[2].to_i}" : nil)
        canon ||= (m && (l.language.in?(%w[he arc hbo]) ? "H#{m[2].to_i}" : "G#{m[2].to_i}"))
        if canon && (g = good_gloss[canon])
          l.update_columns(primary_gloss: g)
          bucket2 += 1
          next
        end
      end

      # Bucket 3: last resort — strip the parenthetical and any leading dash.
      stripped = raw.sub(/\A\([^)]*\)\s*-?\s*/, "").strip
      # If stripping removed everything, just drop the parens themselves
      # (e.g. "(woad)" → "woad").
      stripped = raw.delete("()").strip if stripped.empty?
      if stripped.present? && stripped != raw
        l.update_columns(primary_gloss: stripped)
        bucket3 += 1
      end
    end

    puts "  recovered from '; tail':           #{bucket1}"
    puts "  rederived from TBESH by Strong's:  #{bucket2}"
    puts "  fell back to prefix-strip:         #{bucket3}"
    remaining = Lemma.where("primary_gloss ~ ?", '^\(').count
    puts "Remaining parenthetical-prefix lemmas: #{remaining}"
  end
end
