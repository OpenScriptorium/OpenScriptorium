namespace :import do
  desc "Import the Berean Standard Bible from bereanbible.com"
  task bsb: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::BsbImporter.new(download: download).call
  end

  desc "Import the Berean interlinear tables (WLC Hebrew + Nestle 1904 Greek)"
  task bsb_tables: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::BsbTablesImporter.new(download: download).call
  end

  desc "Import the Robinson-Pierpont Byzantine Greek New Testament"
  task rp: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::RobinsonPierpontImporter.new(download: download).call
  end

  desc "Import the Rahlfs Septuagint (1935) Greek text"
  task rahlfs: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::RahlfsImporter.new(download: download).call
  end

  desc "Import Brenton's English translation of the Septuagint (1851)"
  task brenton: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::BrentonImporter.new(download: download).call
  end

  desc "Import STEPBible TVTMS verse mapping data (LXX/MT/Vulgate ↔ KJV)"
  task tvtms: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::TvtmsImporter.new(download: download).call
  end

  desc "Import the King James Version (1769) with Apocrypha + 1611 marginal notes"
  task kjva: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::KjvaImporter.new(download: download).call
  end

  desc "Import the JPS 1917 English Tanakh + footnotes from JPS Press's PDF"
  task jps1917: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::Jps1917Importer.new(download: download).call
  end

  desc "Import the Lutherbibel 1912 (German) from the Karl-Barth TEI"
  task luther1912: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::Luther1912Importer.new(download: download).call
  end

  desc "Add Strong's numbers and lemmas to the KJV from kaiserlik/kjv"
  task kjv_strongs: :environment do
    Importers::KjvStrongsImporter.new.call
  end

  desc "Import the Louis Segond 1910 French Bible from USFM"
  task segond: :environment do
    Importers::SegondImporter.new.call
  end

  desc "Add morphology and lemmas to Rahlfs LXX from CATSS parsed Septuagint"
  task rahlfs_morph: :environment do
    Importers::RahlfsMorphImporter.new.call
  end

  desc "Import the CNTR Statistical Restoration Greek NT (CC BY 4.0)"
  task cntr_sr: :environment do
    Importers::CntrSrImporter.new.call
  end

  desc "Import OpenBible.info cross-references (CC BY 4.0, ~344k links)"
  task openbible_xrefs: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::OpenbibleXrefsImporter.new(download: download).call
  end

  desc "Import Treasury of Scripture Knowledge cross-references (CC BY-SA 4.0, ~305k links)"
  task tsk: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::TskImporter.new(download: download).call
  end

  desc "Import critical apparatus from CNTR manuscript transcriptions (CC BY-SA 4.0)"
  task cntr_apparatus: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::CntrApparatusImporter.new(download: download).call
  end

  desc "Import Nestle 1904 apparatus from WHNU-guided DjVu extraction (PD)"
  task nestle_apparatus: :environment do
    Importers::NestleApparatusImporter.new.call
  end

  desc "Import the Crampon 1904 French Catholic Bible (PD, 73 books with deuterocanon)"
  task crampon: :environment do
    Importers::CramponImporter.new.call
  end

  desc "Import the Clementine Vulgate (Latin, PD, 78 books with deuterocanon)"
  task vulgate: :environment do
    Importers::VulgateImporter.new.call
  end

  desc "Import the 1904 Patriarchal Greek NT (Orthodox, PD, with Strong's)"
  task patriarchal_nt: :environment do
    Importers::PatriarchalNtImporter.new.call
  end

  desc "Add Brenton's translator footnotes from the USFM edition"
  task brenton_notes: :environment do
    Importers::BrentonNotesImporter.new.call
  end

  desc "Import WEBBE (World English Bible British Edition with Deuterocanon, PD)"
  task webbe: :environment do
    Importers::WebbeImporter.new.call
  end

  desc "Add Ketiv/Qere notes + parashot to WLC from OSHB MAPM XML"
  task oshb_features: :environment do
    Importers::OshbFeaturesImporter.new.call
  end

  desc "Import Babylonian Talmud (Gemara + Rashi + Tosafot) from Sefaria export"
  task bavli: :environment do
    Importers::BavliImporter.new.call
  end

  desc "Import Sefaria cross-reference links (Talmud↔Tanakh, Talmud↔Talmud)"
  task sefaria_links: :environment do
    Importers::SefariaLinksImporter.new.call
  end

  desc "Import Vilna margin commentaries (Rashash, Maharsha, Gilyon HaShas, etc.)"
  task vilna_margins: :environment do
    Importers::VilnaMarginsImporter.new.call
  end

  desc "Import Soncino English Talmud from halakhah.com"
  task soncino: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::SoncinoImporter.new(download: download).call
  end

  desc "Import Ein Mishpat / Mesoret HaShas margin references from Sefaria links"
  task vilna_refs: :environment do
    Importers::VilnaRefsImporter.new.call
  end
end
