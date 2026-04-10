require "json"

module Importers
  # Imports the Clementine Vulgate (Latin Bible).
  #
  # Source: scrollmapper/bible_databases VulgClementine.json
  # License: Public domain (1592 edition, standardized 1598)
  # Language: Latin
  # Coverage: 78 books — full Catholic canon with deuterocanon
  #
  # The Clementine Vulgate is the official Latin Bible of the Roman
  # Catholic Church from 1592 until the Nova Vulgata replaced it in
  # 1979. It is a revision of Jerome's 4th-century translation from
  # Hebrew and Greek, standardized under Pope Clement VIII.
  class VulgateImporter < BaseImporter
    DEFAULT_PATH = Rails.root.join("tmp/vulgate_clementine.json")

    BOOK_MAP = {
      "Genesis" => "genesis", "Exodus" => "exodus",
      "Leviticus" => "leviticus", "Numbers" => "numbers",
      "Deuteronomy" => "deuteronomy", "Joshua" => "joshua",
      "Judges" => "judges", "Ruth" => "ruth",
      "I Samuel" => "1-samuel", "II Samuel" => "2-samuel",
      "I Kings" => "1-kings", "II Kings" => "2-kings",
      "I Chronicles" => "1-chronicles", "II Chronicles" => "2-chronicles",
      "Ezra" => "ezra", "Nehemiah" => "nehemiah", "Esther" => "esther",
      "Job" => "job", "Psalms" => "psalms", "Proverbs" => "proverbs",
      "Ecclesiastes" => "ecclesiastes",
      "Song of Solomon" => "song-of-solomon",
      "Isaiah" => "isaiah", "Jeremiah" => "jeremiah",
      "Lamentations" => "lamentations", "Ezekiel" => "ezekiel",
      "Daniel" => "daniel",
      "Hosea" => "hosea", "Joel" => "joel", "Amos" => "amos",
      "Obadiah" => "obadiah", "Jonah" => "jonah", "Micah" => "micah",
      "Nahum" => "nahum", "Habakkuk" => "habakkuk",
      "Zephaniah" => "zephaniah", "Haggai" => "haggai",
      "Zechariah" => "zechariah", "Malachi" => "malachi",
      "Matthew" => "matthew", "Mark" => "mark", "Luke" => "luke",
      "John" => "john", "Acts" => "acts", "Romans" => "romans",
      "I Corinthians" => "1-corinthians",
      "II Corinthians" => "2-corinthians",
      "Galatians" => "galatians", "Ephesians" => "ephesians",
      "Philippians" => "philippians", "Colossians" => "colossians",
      "I Thessalonians" => "1-thessalonians",
      "II Thessalonians" => "2-thessalonians",
      "I Timothy" => "1-timothy", "II Timothy" => "2-timothy",
      "Titus" => "titus", "Philemon" => "philemon",
      "Hebrews" => "hebrews", "James" => "james",
      "I Peter" => "1-peter", "II Peter" => "2-peter",
      "I John" => "1-john", "II John" => "2-john",
      "III John" => "3-john",
      "Jude" => "jude", "Revelation" => "revelation",
      # Deuterocanon
      "Tobit" => "tobit", "Judith" => "judith",
      "Wisdom" => "wisdom", "Sirach" => "sirach",
      "Baruch" => "baruch",
      "I Maccabees" => "1-maccabees",
      "II Maccabees" => "2-maccabees",
      "Additions to Esther" => "esther-greek",
      "Prayer of Azariah" => "prayer-of-azariah",
      "Susanna" => "susanna",
      "Bel and the Dragon" => "bel-and-the-dragon",
      "Prayer of Manasses" => "prayer-of-manasseh",
      "I Esdras" => "1-esdras",
      "II Esdras" => "2-esdras"
    }.freeze

    def initialize(path: nil, **opts)
      super(**opts)
      @path = path || DEFAULT_PATH
    end

    protected

    def source_url
      "https://github.com/scrollmapper/bible_databases"
    end

    def source_format
      "json"
    end

    def transactional?
      false
    end

    def perform
      @license = License.find_by!(name: "Public Domain")
      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")
      @work = ensure_work

      data = JSON.parse(File.read(@path))
      data["books"].each do |book_data|
        process_book(book_data)
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current)
    end

    private

    def ensure_work
      Work.find_or_initialize_by(slug: "vulgate-clementine").tap do |w|
        w.assign_attributes(
          title: "Clementine Vulgate",
          native_title: "Biblia Sacra Vulgata Clementina",
          work_type: "scripture_translation",
          language: "la",
          traditions: ["χ-catholic"],
          genre: "translation",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://github.com/scrollmapper/bible_databases",
          publication_year: 1592,
          has_word_data: false,
          description: "The Clementine Vulgate (Biblia Sacra Vulgata Clementina), the official Latin Bible of the Roman Catholic Church from 1592 to 1979. A revision of Jerome's 4th-century translation from Hebrew and Greek, standardized under Pope Clement VIII. Includes the full deuterocanonical books. The foundational text of Western Christian liturgy, theology, and scholarship for over a millennium."
        )
        stamp(w)
        w.save!
      end
    end

    def process_book(book_data)
      name = book_data["name"]
      slug = BOOK_MAP[name]
      unless slug
        bump(:books_skipped)
        Rails.logger.info "[VulgateImporter] no mapping for #{name.inspect}"
        return
      end

      canonical_work = CanonicalWork.find_by(slug: slug)
      unless canonical_work
        bump(:books_no_canonical_work)
        return
      end

      book_data["chapters"].each do |chapter_data|
        chapter = chapter_data["chapter"]
        chapter_data["verses"].each do |v|
          process_verse(canonical_work, chapter, v["verse"], v["text"])
        end
      end
      bump(:books_imported)
    end

    def process_verse(canonical_work, chapter, verse_n, text)
      canonical_ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse_n]
      ).first
      unless canonical_ref
        bump(:verses_skipped_no_canonical_ref)
        return
      end

      body = text.to_s.gsub(/\s+/, " ").strip
      return if body.empty?

      work_unit = WorkUnit.find_or_initialize_by(
        work_id: @work.id,
        canonical_ref_id: canonical_ref.id
      )
      if work_unit.new_record?
        work_unit.assign_attributes(
          ord: next_work_unit_ord,
          label: "#{chapter}:#{verse_n}",
          canonical_alignment_type: "exact"
        )
      end
      work_unit.body = body
      stamp(work_unit)
      work_unit.save!
      bump(:verses_imported)
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end
  end
end
