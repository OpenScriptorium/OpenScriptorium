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
  # - Every importer creates an ImportRun row at the start, stamps every
  #   row it creates with that run's id (subclasses use #stamp), and
  #   marks the run completed/failed at the end. This pairs with
  #   PaperTrail to give academic-grade reproducibility provenance.
  #
  # Subclasses must implement #perform.
  class BaseImporter
    attr_reader :stats, :import_run

    def initialize(**opts)
      @opts  = opts
      @stats = Hash.new(0)
    end

    def call
      Rails.logger.info "[#{self.class.name}] starting"
      @import_run = ImportRun.create!(
        importer_class: self.class.name,
        source_url:     source_url,
        source_format:  source_format,
        started_at:     Time.current,
        status:         "running",
        options:        @opts
      )

      started = Time.now
      begin
        if transactional?
          ActiveRecord::Base.transaction { perform }
        else
          perform
        end
        @import_run.complete!(stats: @stats)
        Rails.logger.info "[#{self.class.name}] done in #{(Time.now - started).round(2)}s — #{report}"
        stats
      rescue => e
        @import_run.fail!(e)
        raise
      end
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

    # Override to declare the source URL the importer is reading from.
    def source_url
      nil
    end

    # Override to declare the source format ('tsv', 'json', 'xml', ...).
    def source_format
      nil
    end

    def report
      stats.map { |k, v| "#{k}=#{v}" }.join(", ")
    end

    def bump(key, n = 1)
      @stats[key] += n
    end

    # Stamp a record with our import_run_id if the model supports it.
    # Use this to attach every created/updated record to the run.
    def stamp(record)
      record.import_run_id = @import_run.id if record.respond_to?(:import_run_id=)
      record
    end
  end
end
