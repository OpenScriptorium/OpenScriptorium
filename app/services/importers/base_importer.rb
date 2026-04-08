module Importers
  # Base class for all corpus importers. Conventions:
  #
  # - Importers are SERVICE OBJECTS, instantiated with their config
  #   and called via #call.
  # - Importers MUST be idempotent. Re-running an importer over an
  #   unchanged source produces zero database diffs.
  # - Importers MUST be resumable: a partial run can pick up where it
  #   left off (typically by skipping records that already exist via
  #   find_or_initialize).
  # - Importers run inside a single ActiveRecord transaction by default.
  #   Override #transactional? if your importer needs incremental commits
  #   for very large corpora.
  # - Importers log progress via Rails.logger and a one-line summary at
  #   the end via #report.
  #
  # Subclasses must implement #perform.
  class BaseImporter
    attr_reader :stats

    def initialize(**opts)
      @opts  = opts
      @stats = Hash.new(0)
    end

    def call
      Rails.logger.info "[#{self.class.name}] starting"
      started = Time.now
      if transactional?
        ActiveRecord::Base.transaction { perform }
      else
        perform
      end
      Rails.logger.info "[#{self.class.name}] done in #{(Time.now - started).round(2)}s — #{report}"
      stats
    end

    protected

    # Override in subclasses to do the actual import.
    def perform
      raise NotImplementedError
    end

    # Override to disable single-transaction behavior for very large
    # imports that need incremental commits.
    def transactional?
      true
    end

    def report
      stats.map { |k, v| "#{k}=#{v}" }.join(", ")
    end

    def bump(key, n = 1)
      @stats[key] += n
    end
  end
end
