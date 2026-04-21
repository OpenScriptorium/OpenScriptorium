namespace :db do
  desc "Push local development database to production (streams via SSH, no intermediate files)"
  task :push_to_prod do
    server = "seth@sethkush.com"
    local_db = "openscriptorium_development"
    remote_db = "openscriptorium_production"

    puts "=== Pushing #{local_db} → #{server}:#{remote_db} ==="
    puts ""
    puts "This will DESTROY all data in the production database."
    print "Type 'yes' to continue: "
    abort "Aborted." unless $stdin.gets.strip == "yes"

    # Step 1: Wipe the remote schema (but keep extensions)
    puts "\n[1/6] Dropping remote schema..."
    drop_sql = [
      "DROP SCHEMA public CASCADE",
      "CREATE SCHEMA public",
      "CREATE EXTENSION IF NOT EXISTS vector",
      "CREATE EXTENSION IF NOT EXISTS btree_gist",
      "CREATE EXTENSION IF NOT EXISTS pg_trgm",
      "CREATE EXTENSION IF NOT EXISTS unaccent",
      "CREATE EXTENSION IF NOT EXISTS ltree"
    ].join("; ")

    unless system("ssh", server, "psql -d #{remote_db} -c \"#{drop_sql}\"")
      abort "Failed to drop remote schema."
    end

    # Step 2: Verify it's clean
    puts "\n[2/6] Verifying remote is empty..."
    count = `ssh #{server} "psql -t -d #{remote_db} -c \\"SELECT count(*) FROM pg_tables WHERE schemaname = 'public';\\""`.strip
    abort "Remote schema not empty (#{count} tables). Aborting." unless count == "0"
    puts "  ✓ 0 tables, clean slate"

    # Step 3: Stream the dump
    puts "\n[3/6] Streaming pg_dump → pg_restore (this takes a while)..."
    puts "  Monitor: tail -f /tmp/pgrestore_progress.log"
    puts ""

    cmd = "pg_dump -Fc -v #{local_db} " \
          "2>/tmp/pgdump_progress.log | " \
          "ssh #{server} \"pg_restore -v --no-owner --no-acl -d #{remote_db}\" " \
          "2>/tmp/pgrestore_progress.log"

    unless system("bash", "-c", cmd)
      # pg_restore returns non-zero even on harmless warnings (e.g. extension ownership)
      # Check if the important data actually landed
      wu_count = `ssh #{server} "psql -t -d #{remote_db} -c \\"SELECT count(*) FROM work_units;\\""`.strip.to_i
      if wu_count > 0
        puts "\n⚠  pg_restore exited with warnings but data looks good (#{wu_count} work_units)."
      else
        abort "\n✗ Restore failed — 0 work_units on remote. Check /tmp/pgrestore_progress.log"
      end
    end

    # Step 4: Verify indexes and recreate any that pg_restore missed
    puts "\n[4/6] Checking indexes..."
    local_count = `psql -t -d #{local_db} -c "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public';"`.strip
    remote_count = `ssh #{server} "psql -t -d #{remote_db} -c \\"SELECT count(*) FROM pg_indexes WHERE schemaname = 'public';\\""`.strip

    if local_count != remote_count
      puts "  ⚠  Index mismatch: local=#{local_count}, remote=#{remote_count}. Recreating missing indexes..."

      # Dump missing index definitions and apply them
      remote_indexes = `ssh #{server} "psql -t -d #{remote_db} -c \\"SELECT indexname FROM pg_indexes WHERE schemaname = 'public';\\""`.split.map(&:strip)
      local_indexes_sql = `psql -t -d #{local_db} -c "SELECT indexdef || ';' FROM pg_indexes WHERE schemaname = 'public' ORDER BY indexname;"`.lines.map(&:strip).reject(&:empty?)

      missing = local_indexes_sql.reject { |sql| remote_indexes.any? { |ri| sql.include?(ri) } }

      if missing.any?
        IO.popen(["ssh", server, "psql -d #{remote_db}"], "w") do |io|
          missing.each { |sql| io.puts(sql) }
        end
        puts "  ✓ Created #{missing.size} missing indexes"
      end
    else
      puts "  ✓ All #{local_count} indexes present"
    end

    # Step 5: Prewarm critical tables and indexes into shared_buffers
    puts "\n[5/6] Prewarming cache..."
    prewarm_sql = %w[
      work_units canonical_refs works words lemmas
      idx_work_units_body_tsvector index_work_units_on_work_id
      index_work_units_on_canonical_ref_id index_work_units_on_work_id_and_ord
      index_canonical_refs_on_canonical_work_id_and_ord
      index_words_on_work_unit_id index_words_on_lemma_id
    ].map { |rel| "SELECT pg_prewarm('#{rel}');" }.join(" ")

    system("ssh", server, "psql -d #{remote_db} -c \"CREATE EXTENSION IF NOT EXISTS pg_prewarm; #{prewarm_sql}\"")
    puts "  ✓ Cache warmed"

    # Step 6: Verify data
    puts "\n[6/6] Verifying data..."
    result = `ssh #{server} "psql -t -d #{remote_db} -c \\"SELECT 'work_units: ' || count(*) FROM work_units UNION ALL SELECT 'words: ' || count(*) FROM words UNION ALL SELECT 'works: ' || count(*) FROM works;\\""`.strip
    puts result
    puts "\n✓ Done. Run 'cap production deploy' to restart the app."
  end
end
