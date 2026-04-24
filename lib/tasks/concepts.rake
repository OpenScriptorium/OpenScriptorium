namespace :concepts do
  desc "Load curated search concepts from db/seeds/concepts/*.yaml into the DB. Idempotent."
  task seed: :environment do
    require "yaml"

    files = Dir.glob(Rails.root.join("db/seeds/concepts/*.yaml")).sort
    if files.empty?
      puts "No YAML files under db/seeds/concepts/"
      exit 1
    end

    run = ImportRun.create!(
      importer_class: "ConceptsSeed",
      source_url: "tmp/concepts/",
      started_at: Time.current,
      status: "running",
      options: { files: files.map { |f| File.basename(f) } }
    )

    created = 0
    updated = 0
    verse_total = 0
    unresolved = []

    begin
      ActiveRecord::Base.transaction do
        files.each do |file|
          entries = YAML.load_file(file)
          entries.each do |entry|
            name = entry.fetch("name")
            concept = SearchConcept.find_or_initialize_by(name: name)
            was_new = concept.new_record?

            concept.assign_attributes(
              description: entry["description"],
              aliases:     (entry["aliases"] || []).map { |a| a.to_s.downcase.strip }.reject(&:blank?).uniq,
              kind:        entry.fetch("kind"),
              import_run_id: run.id
            )
            concept.save!

            # Replace verses idempotently
            concept.search_concept_verses.destroy_all
            (entry["verses"] || []).each do |v|
              cite = v.fetch("citation")
              # An SBL citation is shared across versification schemes, so
              # multiple canonical_refs can match. Prefer the one that has
              # English work_units linked (i.e. the scheme that actually
              # carries the text). Fall back to the first match only if no
              # such cref exists.
              cref = CanonicalRef
                .joins(work_units: :work)
                .where(sbl_citation: cite, works: { language: "en" })
                .first
              cref ||= CanonicalRef.find_by(sbl_citation: cite)
              unless cref
                unresolved << [name, cite]
                next
              end
              SearchConceptVerse.create!(
                search_concept_id: concept.id,
                canonical_ref_id:  cref.id,
                role:   v.fetch("role"),
                weight: v.fetch("weight", 1.0),
                import_run_id: run.id
              )
              verse_total += 1
            end

            was_new ? (created += 1) : (updated += 1)
          end
        end
      end

      run.update!(
        finished_at: Time.current,
        status: "completed",
        stats: {
          concepts_created: created,
          concepts_updated: updated,
          verses_total:     verse_total,
          unresolved:       unresolved.size
        }
      )

      puts "Loaded #{created + updated} concepts (#{created} new, #{updated} updated), #{verse_total} verses"
      if unresolved.any?
        puts "\n#{unresolved.size} unresolved citations:"
        unresolved.first(20).each { |name, cite| puts "  #{name.inspect} → #{cite.inspect}" }
      end
    rescue => e
      run.update!(finished_at: Time.current, status: "failed", stats: { error: e.message })
      raise
    end
  end

  desc "Clear all search concepts (DESTROYS curator data)"
  task clear: :environment do
    n = SearchConcept.count
    print "About to destroy #{n} concepts and their links. Type 'yes' to continue: "
    abort "Aborted." unless $stdin.gets.strip == "yes"
    SearchConcept.destroy_all
    puts "Cleared #{n} concepts."
  end
end
