# Pre-load the ONNX embedding model on Puma boot in production so that
# the first semantic search after a deploy doesn't pay an ~11s model-load
# tax. Skipped in dev/test (slow boots) and when the model file isn't
# present (e.g. on a fresh machine before the model has been pulled).
# Skip if we're running a rake task (assets:precompile, db:migrate, etc.)
# or anything that isn't a long-running server process. Puma's CLI sets
# $PROGRAM_NAME to "puma" (or contains it), and rails-server boots via
# the "server" subcommand. Bundler may have autoloaded Rake without an
# application instance, so don't rely on Rake.application being set.
program = $PROGRAM_NAME.to_s
is_server_process = program.include?("puma") || (defined?(Rails::Command) && program.include?("rails")) ||
                    ARGV.first == "server" || ARGV.first == "s"
if Rails.env.production? && is_server_process
  Rails.application.config.after_initialize do
    Thread.new do
      begin
        if Search::EmbeddingEncoder.instance.model_available?
          Rails.logger.info "[EmbeddingWarmup] preloading ONNX model"
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Search::EmbeddingEncoder.instance.preload!
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
          Rails.logger.info "[EmbeddingWarmup] ready in #{elapsed}ms"
        end
      rescue => e
        Rails.logger.warn "[EmbeddingWarmup] failed: #{e.class}: #{e.message}"
      end
    end
  end
end
