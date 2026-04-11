namespace :export do
  desc "Generate bulk download files (SQLite + CSV) in public/downloads/"
  task bulk: :environment do
    require "sqlite3"
    require "csv"
    require "fileutils"

    out_dir = Rails.root.join("public/downloads")
    FileUtils.mkdir_p(out_dir)

    generate_sqlite(out_dir)
    generate_csvs(out_dir)

    puts "Exports written to #{out_dir}"
  end
end

def generate_sqlite(out_dir)
  path = out_dir.join("openscriptorium.sqlite3")
  File.delete(path) if File.exist?(path)

  db = SQLite3::Database.new(path.to_s)
  db.execute("PRAGMA journal_mode=WAL")

  # -- Schema --
  db.execute_batch(<<~SQL)
    CREATE TABLE licenses (
      id INTEGER PRIMARY KEY, name TEXT, spdx_id TEXT, url TEXT,
      attribution_required INTEGER
    );
    CREATE TABLE works (
      id INTEGER PRIMARY KEY, slug TEXT, title TEXT, native_title TEXT,
      work_type TEXT, language TEXT, traditions TEXT,
      license_id INTEGER, source_url TEXT, publication_year INTEGER,
      description TEXT,
      FOREIGN KEY (license_id) REFERENCES licenses(id)
    );
    CREATE TABLE canonical_works (
      id INTEGER PRIMARY KEY, slug TEXT, title TEXT, book_key TEXT,
      testament TEXT, citation_format TEXT, sbl_abbreviation TEXT
    );
    CREATE TABLE canonical_refs (
      id INTEGER PRIMARY KEY, canonical_work_id INTEGER, ord INTEGER,
      hierarchy TEXT, display_label TEXT, sbl_citation TEXT,
      FOREIGN KEY (canonical_work_id) REFERENCES canonical_works(id)
    );
    CREATE TABLE work_units (
      id INTEGER PRIMARY KEY, work_id INTEGER, canonical_ref_id INTEGER,
      ord INTEGER, label TEXT, body TEXT, markup TEXT,
      FOREIGN KEY (work_id) REFERENCES works(id),
      FOREIGN KEY (canonical_ref_id) REFERENCES canonical_refs(id)
    );
    CREATE TABLE work_unit_notes (
      id INTEGER PRIMARY KEY, work_unit_id INTEGER,
      position_in_unit INTEGER, note_type TEXT,
      anchor_text TEXT, body TEXT,
      FOREIGN KEY (work_unit_id) REFERENCES work_units(id)
    );
    CREATE TABLE cross_references (
      id INTEGER PRIMARY KEY,
      source_canonical_work_id INTEGER, source_range_start INTEGER, source_range_end INTEGER,
      target_canonical_work_id INTEGER, target_range_start INTEGER, target_range_end INTEGER,
      relationship_type TEXT, confidence REAL, source_dataset TEXT,
      FOREIGN KEY (source_canonical_work_id) REFERENCES canonical_works(id),
      FOREIGN KEY (target_canonical_work_id) REFERENCES canonical_works(id)
    );
    CREATE TABLE words (
      id INTEGER PRIMARY KEY, work_id INTEGER, work_unit_id INTEGER,
      position INTEGER, surface TEXT, normalized TEXT,
      strongs_number TEXT, morph_code TEXT,
      FOREIGN KEY (work_id) REFERENCES works(id),
      FOREIGN KEY (work_unit_id) REFERENCES work_units(id)
    );
  SQL

  # -- Data --
  puts "  Exporting licenses..."
  License.find_each do |l|
    db.execute("INSERT INTO licenses VALUES (?,?,?,?,?)",
      [l.id, l.name, l.spdx_id, l.url, l.attribution_required ? 1 : 0])
  end

  puts "  Exporting works..."
  Work.find_each do |w|
    db.execute("INSERT INTO works VALUES (?,?,?,?,?,?,?,?,?,?,?)",
      [w.id, w.slug, w.title, w.native_title, w.work_type, w.language,
       w.traditions&.join(","), w.license_id, w.source_url,
       w.publication_year, w.description])
  end

  puts "  Exporting canonical_works..."
  CanonicalWork.find_each do |cw|
    db.execute("INSERT INTO canonical_works VALUES (?,?,?,?,?,?,?)",
      [cw.id, cw.slug, cw.title, cw.book_key, cw.testament,
       cw.citation_format, cw.sbl_abbreviation])
  end

  puts "  Exporting canonical_refs..."
  db.transaction do
    CanonicalRef.find_each do |cr|
      db.execute("INSERT INTO canonical_refs VALUES (?,?,?,?,?,?)",
        [cr.id, cr.canonical_work_id, cr.ord,
         cr.hierarchy&.join(","), cr.display_label, cr.sbl_citation])
    end
  end

  puts "  Exporting work_units..."
  db.transaction do
    WorkUnit.find_each do |wu|
      db.execute("INSERT INTO work_units VALUES (?,?,?,?,?,?,?)",
        [wu.id, wu.work_id, wu.canonical_ref_id, wu.ord, wu.label,
         wu.body, wu.markup&.to_json])
    end
  end

  puts "  Exporting work_unit_notes..."
  db.transaction do
    WorkUnitNote.find_each do |n|
      db.execute("INSERT INTO work_unit_notes VALUES (?,?,?,?,?,?)",
        [n.id, n.work_unit_id, n.position_in_unit, n.note_type,
         n.anchor_text, n.body])
    end
  end

  puts "  Exporting cross_references..."
  db.transaction do
    CrossReference.approved.find_each do |xr|
      db.execute("INSERT INTO cross_references VALUES (?,?,?,?,?,?,?,?,?,?)",
        [xr.id, xr.source_canonical_work_id, xr.source_range&.begin,
         xr.source_range&.end, xr.target_canonical_work_id,
         xr.target_range&.begin, xr.target_range&.end,
         xr.relationship_type, xr.confidence&.to_f, xr.source_dataset])
    end
  end

  puts "  Exporting words..."
  db.transaction do
    Word.find_each do |w|
      db.execute("INSERT INTO words VALUES (?,?,?,?,?,?,?,?)",
        [w.id, w.work_id, w.work_unit_id, w.position, w.surface,
         w.normalized, w.strongs_number, w.morph_code])
    end
  end

  # -- Indexes --
  puts "  Creating indexes..."
  db.execute_batch(<<~SQL)
    CREATE INDEX idx_work_units_work ON work_units(work_id);
    CREATE INDEX idx_work_units_cref ON work_units(canonical_ref_id);
    CREATE INDEX idx_crefs_cw ON canonical_refs(canonical_work_id, ord);
    CREATE INDEX idx_xrefs_source ON cross_references(source_canonical_work_id);
    CREATE INDEX idx_xrefs_target ON cross_references(target_canonical_work_id);
    CREATE INDEX idx_words_work_unit ON words(work_unit_id, position);
    CREATE INDEX idx_notes_work_unit ON work_unit_notes(work_unit_id);
  SQL

  db.execute("VACUUM")
  db.close

  size = File.size(path)
  puts "  SQLite: #{(size / 1024.0 / 1024).round(1)} MB"
end

def generate_csvs(out_dir)
  csv_dir = out_dir.join("csv")
  FileUtils.mkdir_p(csv_dir)

  # Per-work verse exports via raw SQL for speed
  puts "  Exporting per-work CSVs..."
  cw_cache = CanonicalWork.all.index_by(&:id)
  Work.order(:slug).each do |work|
    path = csv_dir.join("#{work.slug}.csv")
    rows = ActiveRecord::Base.connection.select_all(<<~SQL)
      SELECT cw.book_key, cr.hierarchy, wu.label, wu.body
      FROM work_units wu
      JOIN canonical_refs cr ON cr.id = wu.canonical_ref_id
      JOIN canonical_works cw ON cw.id = cr.canonical_work_id
      WHERE wu.work_id = #{work.id}
      ORDER BY cr.ord
    SQL
    CSV.open(path, "w") do |csv|
      csv << %w[book chapter verse label body]
      rows.each do |row|
        h = row["hierarchy"]
        csv << [row["book_key"], h[0], h[1], row["label"], row["body"]]
      end
    end
    puts "    #{work.slug}.csv (#{rows.count} rows)"
  end

  # Cross-references via raw SQL
  puts "  Exporting cross-references CSV..."
  path = csv_dir.join("cross_references.csv")
  xref_rows = ActiveRecord::Base.connection.select_all(<<~SQL)
    SELECT
      scw.book_key AS source_book,
      scr.hierarchy AS source_hierarchy,
      tcw.book_key AS target_book,
      tcr.hierarchy AS target_hierarchy,
      xr.relationship_type,
      xr.source_dataset
    FROM cross_references xr
    JOIN canonical_works scw ON scw.id = xr.source_canonical_work_id
    JOIN canonical_refs scr ON scr.canonical_work_id = scw.id AND scr.ord = lower(xr.source_range)
    JOIN canonical_works tcw ON tcw.id = xr.target_canonical_work_id
    JOIN canonical_refs tcr ON tcr.canonical_work_id = tcw.id AND tcr.ord = lower(xr.target_range)
    WHERE xr.status = 'approved'
    ORDER BY scw.book_key, scr.ord
  SQL
  CSV.open(path, "w") do |csv|
    csv << %w[source_book source_chapter source_verse target_book target_chapter target_verse relationship_type source_dataset]
    xref_rows.each do |row|
      sh = row["source_hierarchy"]
      th = row["target_hierarchy"]
      csv << [row["source_book"], sh[0], sh[1],
              row["target_book"], th[0], th[1],
              row["relationship_type"], row["source_dataset"]]
    end
  end
  puts "    cross_references.csv (#{xref_rows.count} rows)"
end
