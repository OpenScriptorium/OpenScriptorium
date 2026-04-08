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
end
