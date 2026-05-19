# Pre-load the ONNX embedding model on Puma boot in production so that
# the first semantic search after a deploy doesn't pay an ~11s model-load
# tax. Skipped in dev/test (slow boots) and when the model file isn't
# present (e.g. on a fresh machine before the model has been pulled).
if Rails.env.production? && defined?(Puma)
  Rails.application.config.after_initialize do
    Thread.new do
      begin
        if Search::EmbeddingEncoder.instance.model_available?
          Rails.logger.info "[EmbeddingWarmup] preloading ONNX model"
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Search::EmbeddingEncoder.instance.encode("warmup")
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
          Rails.logger.info "[EmbeddingWarmup] ready in #{elapsed}ms"
        end
      rescue => e
        Rails.logger.warn "[EmbeddingWarmup] failed: #{e.class}: #{e.message}"
      end
    end
  end
end
