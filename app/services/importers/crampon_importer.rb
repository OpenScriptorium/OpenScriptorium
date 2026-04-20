require "json"

module Importers
  # Imports the Crampon 1904 French Catholic Bible.
  #
  # Source: scrollmapper/bible_databases FreCrampon.json
  # License: Public domain (Augustin Crampon, 1894-1904)
  # Language: French
  # Coverage: 73 books — full Catholic canon with deuterocanon
  #   (Tobit, Judith, Wisdom, Sirach, Baruch, 1-2 Maccabees,
  #   plus additions to Esther and Daniel)
  #
  # The Crampon Bible was the standard French Catholic translation
  # for the first half of the 20th century, translated directly
  # from the Hebrew and Greek (not just the Vulgate). It was
  # superseded by the Bible de Jérusalem in 1956.
  class CramponImporter < BaseImporter
    DEFAULT_PATH = Rails.root.join("tmp/crampon/FreCrampon.json")

    BOOK_MAP = {
      # Protestant 66
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
      Work.find_or_initialize_by(slug: "crampon-1904").tap do |w|
        w.assign_attributes(
          title: "Bible Crampon 1904",
          native_title: "La Sainte Bible traduite en français sous la direction de l'Abbé A. Crampon",
          work_type: "scripture_translation",
          language: "fr",
          traditions: ["χ-catholic"],
          genre: "translation",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://github.com/scrollmapper/bible_databases",
          publication_year: 1904,
          has_word_data: false,
          description: "The Crampon Bible (1894-1904), the standard French Catholic translation for the first half of the 20th century. Translated directly from the Hebrew and Greek by Augustin Crampon (1826-1894), a professor at the Catholic Faculty of Lille. Includes the full deuterocanonical books. Superseded by the Bible de Jérusalem in 1956 but still widely used and freely available as a public domain text."
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
        Rails.logger.info "[CramponImporter] no mapping for #{name.inspect}"
        return
      end

      canonical_work = CanonicalWork.find_by(slug: slug)
      unless canonical_work
        bump(:books_no_canonical_work)
        Rails.logger.warn "[CramponImporter] no canonical_work for #{slug}"
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
      canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse_n])

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
