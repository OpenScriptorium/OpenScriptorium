# Pull the HNSW vector indexes and their base tables into Postgres
# shared_buffers at Puma boot. Cold-cache HNSW probes are what drives
# our p95/p99 tail on semantic search — the first query after a Postgres
# restart hits disk for the graph and pays a multi-hundred-ms tax.
# Prewarming makes that cost happen once, at boot, off the request path.
#
# Runs only in the Puma/Rails server process (same guard as
# embedding_warmup.rb) so migrations, rake tasks, and consoles don't
# pay the cost or contend with pg_prewarm's IO.
#
# Skipped silently if pg_prewarm isn't installed (fresh dev machines,
# or if the migration hasn't run yet).
program = $PROGRAM_NAME.to_s
is_server_process = program.include?("puma") || (defined?(Rails::Command) && program.include?("rails")) ||
                    ARGV.first == "server" || ARGV.first == "s"

if Rails.env.production? && is_server_process
  targets = %w[
    work_unit_embeddings_qwen3_06b
    idx_wue_qwen3_06b_hnsw
    pericopes
    idx_pericopes_name_embedding_qwen3_hnsw
  ].freeze

  Rails.application.config.after_initialize do
    Thread.new do
      conn = nil
      begin
        conn = ActiveRecord::Base.connection_pool.checkout
        # Confirm the extension is present before hitting pg_prewarm().
        has_ext = conn.select_value(
          "SELECT 1 FROM pg_extension WHERE extname = 'pg_prewarm'"
        ).present?
        unless has_ext
          Rails.logger.info "[PgPrewarm] extension not installed, skipping"
          next
        end
        targets.each do |rel|
          exists = conn.select_value(
            "SELECT 1 FROM pg_class WHERE relname = #{conn.quote(rel)}"
          ).present?
          unless exists
            Rails.logger.info "[PgPrewarm] #{rel} not found, skipping"
            next
          end
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          blocks = conn.select_value("SELECT pg_prewarm(#{conn.quote(rel)})")
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
          Rails.logger.info "[PgPrewarm] #{rel}: #{blocks} blocks in #{elapsed}ms"
        end
      rescue => e
        Rails.logger.warn "[PgPrewarm] failed: #{e.class}: #{e.message}"
      ensure
        ActiveRecord::Base.connection_pool.checkin(conn) if conn
      end
    end
  end
end
