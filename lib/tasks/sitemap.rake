desc "Generate sitemap XML files in public/"
task sitemap: :environment do
  require "builder"

  base = "https://openscriptorium.org"
  max_per_file = 49_000
  file_idx = 0
  count_in_file = 0
  total = 0
  xml = nil
  out = nil
  files = []

  open_file = -> {
    file_idx += 1
    name = "sitemap-#{file_idx}.xml"
    files << name
    out = File.open(Rails.root.join("public/#{name}"), "w")
    xml = Builder::XmlMarkup.new(target: out, indent: 2)
    xml.instruct!
    xml.urlset(xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9") {
      # block will be yielded to via add calls
    }
    # Reopen: Builder doesn't support deferred blocks well, use raw XML
    out.close
    out = File.open(Rails.root.join("public/#{name}"), "w")
    out.write %(<?xml version="1.0" encoding="UTF-8"?>\n)
    out.write %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
    count_in_file = 0
  }

  close_file = -> {
    return unless out
    out.write %(</urlset>\n)
    out.close
  }

  add = ->(path, opts = {}) {
    open_file.call if xml.nil? || count_in_file >= max_per_file
    freq = opts[:freq] || "monthly"
    pri = opts[:priority] || "0.5"
    out.write %(<url><loc>#{base}#{path}</loc><changefreq>#{freq}</changefreq><priority>#{pri}</priority></url>\n)
    count_in_file += 1
    total += 1
  }

  # Static pages
  add.call("/", priority: "1.0", freq: "weekly")
  add.call("/works", priority: "0.9", freq: "weekly")
  add.call("/principles", priority: "0.6")
  add.call("/appeal-to-scholars", priority: "0.5")
  add.call("/appeal-to-publishers", priority: "0.5")
  add.call("/about/architecture", priority: "0.3")
  add.call("/about/schema", priority: "0.3")
  add.call("/downloads", priority: "0.5")

  # Work show pages
  hidden = %w[ein-mishpat-bavli mesoret-hashas-bavli]
  Work.where.not(slug: hidden).find_each do |w|
    add.call("/works/#{w.slug}", priority: "0.7")
  end

  # Talmud slugs for daf routing
  talmud_slugs = DafController::TALMUD_SLUG_TO_GEMARA.keys + ["bavli"]

  Work.find_each do |w|
    is_talmud = talmud_slugs.include?(w.slug)

    books = CanonicalWork.joins(canonical_refs: :work_units)
              .where(work_units: { work_id: w.id })
              .select("canonical_works.id, canonical_works.slug, canonical_works.position, canonical_works.citation_format")
              .distinct.order(:position)

    books.each do |cw|
      add.call("/#{w.slug}/#{cw.slug}", priority: "0.6")

      if is_talmud && cw.citation_format == "talmud"
        amudim = CanonicalRef.where(canonical_work_id: cw.id)
                   .distinct
                   .pluck(Arel.sql("hierarchy[1], hierarchy[2]"))
                   .sort_by { |d, a| [d, a] }
                   .uniq
        amudim.each do |daf, amud|
          label = "#{daf}#{amud == 1 ? 'a' : 'b'}"
          add.call("/#{w.slug}/#{cw.slug}/#{label}", priority: "0.5")
        end
      else
        chapters = CanonicalRef.where(canonical_work_id: cw.id)
                     .joins(:work_units)
                     .where(work_units: { work_id: w.id })
                     .distinct
                     .pluck(Arel.sql("hierarchy[1]"))
                     .compact.sort
        chapters.each do |ch|
          add.call("/#{w.slug}/#{cw.slug}/#{ch}", priority: "0.5")
        end
      end
    end
  end

  close_file.call

  # Write sitemap index
  File.open(Rails.root.join("public/sitemap.xml"), "w") do |f|
    f.write %(<?xml version="1.0" encoding="UTF-8"?>\n)
    f.write %(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
    files.each do |name|
      f.write %(<sitemap><loc>#{base}/#{name}</loc></sitemap>\n)
    end
    f.write %(</sitemapindex>\n)
  end

  puts "Sitemap: #{total} URLs in #{files.size} file(s)"
end
