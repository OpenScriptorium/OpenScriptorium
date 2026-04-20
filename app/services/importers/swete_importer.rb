module Importers
  # Imports the Swete Septuagint (The Old Testament in Greek According
  # to the Septuagint, ed. Henry Barclay Swete, 1887-1894).
  #
  # Source: github.com/nathans/lxx-swete (derived from Open Greek and
  # Latin Project's First1KGreek)
  # License: CC BY-SA 4.0
  # Language: Koine Greek
  # Coverage: Complete LXX — 59 books including deuterocanon, Odes,
  # Psalms of Solomon, both Daniel/Susanna/Bel recensions
  #
  # Format: one word per line, "chapter.verse.position WORD"
  # Words are tokenized but have NO morphology or lemma data.
  #
  # The Swete edition differs from Rahlfs in some readings but both
  # are based primarily on Codex Vaticanus.
  class SweteImporter < BaseImporter
    SOURCE_URL = "https://github.com/nathans/lxx-swete.git"
    DEFAULT_DIR = Rails.root.join("tmp/swete")

    # Swete file names → our canonical_works.slug
    BOOK_MAP = {
      "01.Genesis"                         => "genesis",
      "02.Exodus"                          => "exodus",
      "03.Leviticus"                       => "leviticus",
      "04.Numeri"                          => "numbers",
      "05.Deuteronomium"                   => "deuteronomy",
      "06.Josue"                           => "joshua",
      "08.Judices"                         => "judges",
      "10.Ruth"                            => "ruth",
      "11.Regnorum_I"                      => "1-samuel",
      "12.Regnorum_II"                     => "2-samuel",
      "13.Regnorum_III"                    => "1-kings",
      "14.Regnorum_IV"                     => "2-kings",
      "15.Paralipomenon_I"                 => "1-chronicles",
      "16.Paralipomenon_II"                => "2-chronicles",
      "17.Esdras_A"                        => "1-esdras",
      "18.Esdras_B"                        => "ezra",
      "19.Esther"                          => "esther-greek",
      "20.Judith"                          => "judith",
      "21.Tobias"                          => "tobit",
      "23.Machabaeorum_i"                  => "1-maccabees",
      "24.Machabaeorum_ii"                 => "2-maccabees",
      "25.Machabaeorum_iii"                => "3-maccabees",
      "26.Machabaeorum_iv"                 => "4-maccabees",
      "27.Psalmi"                          => "psalms-lxx",
      "28.Odae"                            => "odes",
      "29.Proverbia"                       => "proverbs",
      "31.Canticum"                        => "song-of-solomon",
      "32.Job"                             => "job-lxx",
      "33.Sapientia_Salomonis"             => "wisdom",
      "34.Ecclesiasticus"                  => "sirach",
      "35.Psalmi_Salomonis"                => "psalms-of-solomon",
      "36.Osee"                            => "hosea",
      "37.Amos"                            => "amos",
      "38.Michaeas"                        => "micah",
      "39.Joel"                            => "joel",
      "40.Abdias"                          => "obadiah",
      "41.Jonas"                           => "jonah",
      "42.Nahum"                           => "nahum",
      "43.Habacuc"                         => "habakkuk",
      "44.Sophonias"                       => "zephaniah",
      "45.Aggaeus"                         => "haggai",
      "46.Zacharias"                       => "zechariah",
      "47.Malachias"                       => "malachi",
      "48.Isaias"                          => "isaiah",
      "49.Jeremias"                        => "jeremiah-lxx",
      "50.Baruch"                          => "baruch",
      "51.Threni_seu_Lamentationes"        => "lamentations",
      "52.Epistula_Jeremiae"               => "letter-of-jeremiah",
      "53.Ezechiel"                        => "ezekiel",
      "54.Susanna_translatio_Graeca"       => "susanna",
      "55.Susanna_Theodotionis_versio"     => "susanna-theodotion",
      "56.Daniel_translatio_Graeca"        => "daniel",
      "57.Daniel_Theodotionis_versio"      => "daniel-theodotion",
      "58.Bel_et_Draco_translatio_Graeca"  => "bel-and-the-dragon",
      "59.Bel_et_Draco_Theodotionis_versio" => "bel-and-the-dragon-theodotion",
    }.freeze

    def initialize(dir: nil, download: true, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download
    end

    protected

    def source_url
      SOURCE_URL
    end

    def source_format
      "txt"
    end

    def transactional?
      false
    end

    def perform
      ensure_source!

      @license = License.find_by!(name: "CC BY-SA 4.0") rescue License.find_by!(name: "Public Domain")
      @lxx_scheme = VersificationScheme.find_by!(code: "LXX")
      @work = ensure_work
      @canonical_work_cache = {}

      data_dir = File.join(@dir, "data")
      Dir.glob(File.join(data_dir, "*.txt")).sort.each do |path|
        process_file(path)
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current)
    end

    private

    def ensure_source!
      return if File.directory?(File.join(@dir, "data")) && !@download

      FileUtils.mkdir_p(@dir)
      if File.directory?(File.join(@dir, ".git"))
        system("git", "-C", @dir.to_s, "pull", "--quiet", out: File::NULL) or
          Rails.logger.warn "[SweteImporter] git pull failed"
      else
        system("git", "clone", "--depth=1", SOURCE_URL, @dir.to_s, out: File::NULL) or
          raise "git clone failed for #{SOURCE_URL}"
      end
      bump(:downloaded)
    end

    def ensure_work
      Work.find_or_initialize_by(slug: "swete-lxx").tap do |w|
        w.assign_attributes(
          title: "Swete's Septuagint",
          native_title: "The Old Testament in Greek According to the Septuagint",
          work_type: "scripture_original",
          language: "el-koine",
          traditions: ["academic-old", "χ"],
          genre: "original",
          license: @license,
          default_versification_scheme: @lxx_scheme,
          source_url: "https://github.com/nathans/lxx-swete",
          publication_year: 1894,
          has_word_data: false,
          description: "The Old Testament in Greek According to the Septuagint, " \
                       "edited by Henry Barclay Swete (3 vols., 1887-1894). " \
                       "Based primarily on Codex Vaticanus with readings from " \
                       "Alexandrinus and Sinaiticus. Complete LXX including " \
                       "deuterocanonical books. CC BY-SA 4.0 digitization from " \
                       "the Open Greek and Latin Project."
        )
        stamp(w)
        w.save!
      end
    end

    def process_file(path)
      basename = File.basename(path, ".txt")
      slug = BOOK_MAP[basename]
      if slug.nil?
        if BOOK_MAP.key?(basename)
          bump(:books_skipped_no_slug)
        else
          bump(:books_skipped_unknown)
          Rails.logger.info "[SweteImporter] unknown book: #{basename}"
        end
        return
      end

      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      unless canonical_work
        bump(:books_no_canonical_work)
        Rails.logger.warn "[SweteImporter] no canonical_work for #{slug}"
        return
      end

      # Parse the file: group words by chapter.verse
      current_ref = nil
      current_words = []

      File.foreach(path, encoding: "utf-8") do |line|
        line = line.strip
        next if line.empty?

        # Format: "BOOK.CHAPTER.VERSE WORD" (book number is redundant with filename)
        m = line.match(/\A\d+\.(\d+)\.(\d+)\s+(.+)\z/)
        next unless m

        ref_key = "#{m[1]}.#{m[2]}"
        if ref_key != current_ref
          flush_verse!(canonical_work, current_ref, current_words) if current_ref
          current_ref = ref_key
          current_words = []
        end
        current_words << m[3]
      end
      flush_verse!(canonical_work, current_ref, current_words) if current_ref

      bump(:books_imported)
    end

    def flush_verse!(canonical_work, ref_key, words)
      return if words.empty?

      chapter, verse = ref_key.split(".").map(&:to_i)
      canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse])

      body = words.join(" ")
      return if body.blank?

      work_unit = WorkUnit.find_or_initialize_by(
        work_id: @work.id, canonical_ref_id: canonical_ref.id
      )
      if work_unit.new_record?
        work_unit.assign_attributes(
          ord: next_work_unit_ord,
          label: "#{chapter}:#{verse}",
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
