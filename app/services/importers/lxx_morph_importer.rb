require "json"
require "tmpdir"
require "open3"

module Importers
  # Imports the word-level morphological dataset for the Rahlfs LXX
  # from the lxx-morph repository on sr.ht. Populates the `words` table
  # with surface / lemma / morph_code for every token in every Rahlfs
  # verse that has a matching canonical_ref.
  #
  # Source: https://git.sr.ht/~sethkush/lxx-morph (CC BY 4.0)
  #
  # The importer clones the repo at job start into a tmpdir, imports,
  # and removes the clone on exit. This keeps the openscriptorium
  # working tree free of the ~600MB corpus and ensures each import
  # uses the latest published data.
  #
  # Per-book transactional: a failure mid-book rolls back that book
  # only; books already imported stay imported. Re-running is
  # idempotent — each (work_unit, position) is upserted in place.
  class LxxMorphImporter < BaseImporter
    REPO_URL = "https://git.sr.ht/~sethkush/lxx-morph".freeze

    def perform
      @work = Work.find_by(slug: "rahlfs-lxx")
      unless @work
        Rails.logger.warn "[#{self.class.name}] no Work with slug 'rahlfs-lxx'; run RahlfsImporter first"
        bump(:work_missing)
        return
      end

      data_dir = ENV["LXX_MORPH_PATH"].presence

      if data_dir
        Rails.logger.info "[#{self.class.name}] using LXX_MORPH_PATH=#{data_dir}"
        import_from(data_dir)
      else
        Dir.mktmpdir("lxx-morph") do |tmpdir|
          clone_repo(tmpdir)
          import_from(File.join(tmpdir, "db/seeds/lxx_morph"))
        end
      end
    end

    # Use per-book transactions instead of one wrapping the whole run.
    def transactional? = false

    def source_url   = REPO_URL
    def source_format = "json"

    private

    def clone_repo(tmpdir)
      Rails.logger.info "[#{self.class.name}] cloning #{REPO_URL}"
      out, status = Open3.capture2e("git", "clone", "--depth=1", "--quiet", REPO_URL, tmpdir)
      raise "git clone failed: #{out}" unless status.success?
    end

    def import_from(dir)
      Dir.glob(File.join(dir, "*.json")).sort.each do |path|
        # Skip pipeline intermediates if any slip through.
        next if path.include?(".auto.")
        next if path.end_with?("_null.json")

        book_slug = File.basename(path, ".json")
        ActiveRecord::Base.transaction { import_book(book_slug, path) }
      end
    end

    def import_book(book_slug, path)
      cw = CanonicalWork.find_by(slug: book_slug)
      unless cw
        Rails.logger.info "[#{self.class.name}] no canonical_work for slug=#{book_slug}; skipping"
        bump(:books_skipped_no_canonical_work)
        return
      end

      ref_index = WorkUnit
        .joins(:canonical_ref)
        .where(work_id: @work.id, canonical_refs: { canonical_work_id: cw.id })
        .pluck("canonical_refs.sbl_citation", "work_units.id")
        .to_h

      if ref_index.empty?
        Rails.logger.info "[#{self.class.name}] no Rahlfs work_units for #{book_slug}; skipping"
        bump(:books_skipped_no_work_units)
        return
      end

      data = JSON.parse(File.read(path))
      data.each do |verse|
        wu_id = ref_index[verse["ref"]]
        unless wu_id
          bump(:verses_unmatched)
          next
        end
        import_verse(wu_id, verse["words"])
      end
      bump(:books_imported)
    end

    def import_verse(work_unit_id, words)
      words.each_with_index do |w, idx|
        position = idx + 1
        record = Word.find_or_initialize_by(work_unit_id: work_unit_id, position: position)
        record.work_id    = @work.id
        record.surface    = w["surface"]
        record.normalized = strip_diacritics(w["surface"])
        record.morph_code = morph_code_for(w)
        record.lemma_id   = lemma_id_for(w["lemma"])

        # Check changed? BEFORE stamping the import_run_id, so a
        # re-import of unchanged data is a true no-op (no DB write,
        # no spurious PaperTrail version).
        if record.new_record?
          stamp(record)
          record.save!
          bump(:words_created)
        elsif record.changed?
          stamp(record)
          record.save!
          bump(:words_updated)
        else
          bump(:words_unchanged)
        end
      end

      # Trim trailing rows if a re-import has fewer tokens than the
      # previous run. Rare in practice (the corpus is stable), but it
      # keeps the table honest against verse re-tokenizations.
      Word.where(work_unit_id: work_unit_id)
          .where("position > ?", words.length)
          .delete_all
          .then { |n| bump(:words_trimmed, n) if n > 0 }
    end

    # Concatenate pos + parsing with a single space, dropping blanks.
    # Hebrew indeclinables get "" → morph_code becomes nil.
    def morph_code_for(w)
      [w["pos"], w["parsing"]].reject(&:blank?).join(" ").presence
    end

    def strip_diacritics(s)
      s.to_s.unicode_normalize(:nfd).gsub(/[\p{Mn}]/, "").unicode_normalize(:nfc).downcase
    end

    # Find-or-create a Greek Koine lemma. Cached for the run since the
    # same dictionary form recurs across the entire corpus. Homonym
    # ambiguity (multiple lemmas with the same headword in the existing
    # lemmas table) is resolved by first-match here; finer-grained
    # disambiguation belongs to a future pass that bridges through
    # Strong's or canonical_lemma_id.
    def lemma_id_for(lemma_text)
      return nil if lemma_text.blank?
      @lemma_cache ||= {}
      key = lemma_text.unicode_normalize(:nfc)
      @lemma_cache[key] ||= begin
        existing = Lemma.where(language: "el-koine", lemma: key).order(:id).limit(1).first
        if existing
          existing.id
        else
          l = Lemma.new(
            language:   "el-koine",
            lemma:      key,
            normalized: strip_diacritics(key)
          )
          stamp(l)
          l.save!
          bump(:lemmas_created)
          l.id
        end
      end
    end
  end
end
