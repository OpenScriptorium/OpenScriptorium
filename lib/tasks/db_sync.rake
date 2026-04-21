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
    puts "\n[1/3] Dropping remote schema..."
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
    puts "\n[2/3] Verifying remote is empty..."
    count = `ssh #{server} "psql -t -d #{remote_db} -c \\"SELECT count(*) FROM pg_tables WHERE schemaname = 'public';\\""`.strip
    abort "Remote schema not empty (#{count} tables). Aborting." unless count == "0"
    puts "  ✓ 0 tables, clean slate"

    # Step 3: Stream the dump
    puts "\n[3/3] Streaming pg_dump → pg_restore (this takes a while)..."
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

    # Verify
    puts "\nVerifying..."
    result = `ssh #{server} "psql -t -d #{remote_db} -c \\"SELECT 'work_units: ' || count(*) FROM work_units UNION ALL SELECT 'words: ' || count(*) FROM words UNION ALL SELECT 'works: ' || count(*) FROM works;\\""`.strip
    puts result
    puts "\n✓ Done. Run 'cap production deploy' to restart the app."
  end
end
