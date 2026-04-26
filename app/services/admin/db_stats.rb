module Admin
  # Postgres size + bloat introspection for the admin DB stats page.
  #
  # All queries hit pg_stat_user_* and pg_relation_size — cheap, no scans.
  # Cached for 60 seconds to avoid hammering the catalog on refresh.
  class DbStats
    CACHE_TTL = 60.seconds

    class << self
      def fetch
        Rails.cache.fetch("admin_db_stats", expires_in: CACHE_TTL) do
          {
            generated_at: Time.now.utc.iso8601,
            database:     database_summary,
            tables:       per_table,
          }
        end
      end

      def clear_cache
        Rails.cache.delete("admin_db_stats")
      end

      private

      def conn
        ActiveRecord::Base.connection
      end

      # Top-level: db name, total size, server version.
      def database_summary
        row = conn.select_one(<<~SQL)
          SELECT current_database()                                AS name,
                 pg_database_size(current_database())              AS size_bytes,
                 (SELECT setting FROM pg_settings WHERE name = 'server_version') AS version
        SQL
        {
          name:       row["name"],
          size_bytes: row["size_bytes"].to_i,
          version:    row["version"],
        }
      end

      # Per-table: total size = heap + indexes + TOAST. Each broken out.
      # Sorted by total descending. Includes index detail nested.
      def per_table
        rows = conn.select_all(<<~SQL).to_a
          SELECT
            relname AS name,
            pg_total_relation_size(relid)              AS total_bytes,
            pg_relation_size(relid)                    AS heap_bytes,
            pg_indexes_size(relid)                     AS index_bytes,
            pg_total_relation_size(relid)
              - pg_relation_size(relid)
              - pg_indexes_size(relid)                 AS toast_bytes,
            n_live_tup                                 AS live_rows,
            n_dead_tup                                 AS dead_rows,
            relid::regclass::text                      AS qualified
          FROM pg_stat_user_tables
          ORDER BY pg_total_relation_size(relid) DESC
        SQL

        index_rows = conn.select_all(<<~SQL).to_a.group_by { |r| r["relname"] }
          SELECT
            relname,
            indexrelname           AS index_name,
            pg_relation_size(indexrelid) AS bytes,
            idx_scan               AS scans
          FROM pg_stat_user_indexes
          ORDER BY pg_relation_size(indexrelid) DESC
        SQL

        rows.map do |r|
          name = r["name"]
          {
            name:        name,
            total_bytes: r["total_bytes"].to_i,
            heap_bytes:  r["heap_bytes"].to_i,
            index_bytes: r["index_bytes"].to_i,
            toast_bytes: r["toast_bytes"].to_i,
            live_rows:   r["live_rows"].to_i,
            dead_rows:   r["dead_rows"].to_i,
            indexes:     (index_rows[name] || []).map { |i|
              {
                name:  i["index_name"],
                bytes: i["bytes"].to_i,
                scans: i["scans"].to_i,
              }
            },
          }
        end
      end

    end
  end
end
