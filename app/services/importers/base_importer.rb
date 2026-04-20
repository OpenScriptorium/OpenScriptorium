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

      # Auto-progress: print a summary every 1000 total bumps
      @bump_total = (@bump_total || 0) + n
      if @bump_total % 1000 == 0
        elapsed = @import_run ? (Time.now - @import_run.started_at).round(0) : 0
        summary = @stats.select { |_, v| v > 0 }.map { |k, v| "#{k}:#{v}" }.join(", ")
        $stdout.puts "[#{self.class.name.demodulize}] #{elapsed}s — #{summary}"
        $stdout.flush
      end
    end

    # Stamp a record with our import_run_id if the model supports it.
    # Use this to attach every created/updated record to the run.
    def stamp(record)
      record.import_run_id = @import_run.id if record.respond_to?(:import_run_id=)
      record
    end

    # Concurrent-safe canonical_ref creation. Uses a Postgres advisory
    # lock per canonical_work to prevent ord collisions when multiple
    # importers run in parallel. The lock is transaction-scoped
    # (pg_advisory_xact_lock) so it auto-releases on commit/rollback.
    #
    # Subclasses should call this instead of implementing their own
    # ensure_canonical_ref / find_or_create canonical_ref logic.
    def ensure_canonical_ref(canonical_work, hierarchy, label: nil)
      ref = CanonicalRef.find_by(
        canonical_work_id: canonical_work.id,
        hierarchy: hierarchy
      )
      return ref if ref

      conn = ActiveRecord::Base.connection

      # Advisory lock keyed on canonical_work.id — serializes ord
      # assignment per book so parallel importers don't collide.
      conn.execute("SELECT pg_advisory_xact_lock(#{canonical_work.id.to_i})")

      # Re-check after acquiring lock (another process may have created it)
      ref = CanonicalRef.find_by(
        canonical_work_id: canonical_work.id,
        hierarchy: hierarchy
      )
      return ref if ref

      next_ord = (CanonicalRef.where(canonical_work_id: canonical_work.id).maximum(:ord) || 0) + 1

      display = label || format_hierarchy_label(hierarchy)
      citation = canonical_work.respond_to?(:format_citation) ? canonical_work.format_citation(hierarchy) : display

      ref = CanonicalRef.new(
        canonical_work_id: canonical_work.id,
        hierarchy: hierarchy,
        ord: next_ord,
        display_label: display,
        sbl_citation: citation
      )
      stamp(ref)
      ref.save!
      bump(:canonical_refs_created)
      ref
    end

    # Format a hierarchy array into a human-readable label.
    # [1, 1] → "1:1", [1, 1, 1] → "1:1a", [0, 5] → "0:5"
    def format_hierarchy_label(hierarchy)
      case hierarchy.length
      when 2
        "#{hierarchy[0]}:#{hierarchy[1]}"
      when 3
        "#{hierarchy[0]}:#{hierarchy[1]}#{('a'.ord + hierarchy[2] - 1).chr}"
      when 1
        hierarchy[0].to_s
      else
        hierarchy.join(":")
      end
    end
  end
end
