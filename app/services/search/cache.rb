module Search
  # SolidCache wrapper for Search::Executor#call.
  #
  # A large chunk of real user traffic is repeated: shared links,
  # people typing the same query twice, autocomplete-fed queries that
  # collide across sessions. Every miss on that traffic pays the full
  # FTS + HNSW + concept/topic merge cost. Caching the ResultSet avoids
  # all of it — a hit is a Marshal load out of Postgres SolidCache
  # (single-digit ms) instead of hundreds of ms.
  #
  # Correctness: the cache version is stamped with the max id of the
  # ImportRun table. Any corpus mutation goes through an ImportRun, so
  # a new id after an import busts every cached entry automatically —
  # no manual invalidation required.
  #
  # Opt out per request with SEARCH_CACHE=off in the environment, or
  # by passing skip_cache: true (used by the eval harness to avoid
  # cache-warmed numbers).
  module Cache
    TTL = 15.minutes
    ENABLED = ENV.fetch("SEARCH_CACHE", "on") != "off"

    module_function

    def fetch(query, scope:, page:, per_page:, skip_cache: false, &block)
      return block.call unless ENABLED
      return block.call if skip_cache
      return block.call if query.to_s.strip.empty?

      key = build_key(query, scope, page, per_page)
      Rails.cache.fetch(key, expires_in: TTL, &block)
    rescue => e
      # Never let cache infrastructure take down the search path.
      Rails.logger.warn "[Search::Cache] fetch failed: #{e.class}: #{e.message}"
      block.call
    end

    def build_key(query, scope, page, per_page)
      norm_scope = normalize_scope(scope)
      [
        "search",
        "v1",
        corpus_version,
        query.to_s.downcase.strip,
        norm_scope,
        page.to_i,
        per_page.to_i,
      ]
    end

    # Sort scope keys and stringify values so equivalent scopes hit
    # the same cache slot. Arrays get sorted too — {sections: [nt, ot]}
    # and {sections: [ot, nt]} are the same query.
    def normalize_scope(scope)
      return nil if scope.nil? || scope.empty?
      scope.to_h.transform_values { |v| v.is_a?(Array) ? v.sort : v }.sort.to_h
    end

    # Corpus version = max import_runs.id. Anything that mutates the
    # corpus (importer, backfill, moderation-queue publish) writes an
    # ImportRun, so a new id invalidates the whole cache namespace.
    # Cached in-process for 30s to avoid hammering the DB per request;
    # a slightly stale version just means one extra generation of
    # cached entries lives 30s longer than strictly necessary.
    def corpus_version
      @cv_expiry ||= 0
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @cv.nil? || now > @cv_expiry
        @cv = ImportRun.maximum(:id).to_i
        @cv_expiry = now + 30
      end
      @cv
    rescue ActiveRecord::StatementInvalid, NameError
      # ImportRun table missing (fresh dev, migration not run yet):
      # fall back to a stable placeholder so caching still works.
      0
    end
  end
end
