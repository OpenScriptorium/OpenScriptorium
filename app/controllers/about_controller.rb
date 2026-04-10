class AboutController < ApplicationController
  allow_unauthenticated_access only: [:architecture, :schema, :principles, :appeal_to_scholars, :appeal_to_publishers]

  # Group every model into one of these layers for the schema page.
  # Order matters — it's the rendering order on the page.
  SCHEMA_GROUPS = {
    "Canonical addressing" => %w[
      VersificationScheme CanonicalWork CanonicalRef VersificationMapping
      Pericope
    ],
    "Works"                => %w[
      License Author Work WorkAuthorship WorkUnit WorkUnitNote
    ],
    "Word-level data"      => %w[
      Lemma Word AlignmentGroup AlignmentGroupMember
    ],
    "Critical apparatus"   => %w[
      Manuscript VariantUnit Reading ReadingWitness
    ],
    "Cross-references"     => %w[CrossReference],
    "Users + contributions"=> %w[
      User Invitation Annotation PersonalNote Bookmark
      ReadingPlan ReadingPlanEntry ReadingPlanProgress
    ],
    "Provenance + config"  => %w[ImportRun Setting],
  }.freeze

  def architecture
  end

  def principles
  end

  def appeal_to_scholars
  end

  def schema
    @groups = SCHEMA_GROUPS.transform_values do |class_names|
      class_names.map do |name|
        klass = name.safe_constantize
        next unless klass
        {
          model: klass,
          table: klass.table_name,
          columns: klass.columns,
          associations: klass.reflect_on_all_associations
        }
      end.compact
    end

    # Live corpus stats — computed from the current DB so the page
    # always reflects what's actually loaded.
    @corpus_works = Work.includes(:license).order(:title).map do |w|
      {
        work: w,
        unit_count: WorkUnit.where(work_id: w.id).count
      }
    end
    @corpus_totals = {
      works:                  Work.count,
      canonical_works:        CanonicalWork.count,
      canonical_refs:         CanonicalRef.count,
      work_units:             WorkUnit.count,
      words:                  Word.count,
      lemmas:                 Lemma.count,
      cross_references:       CrossReference.count,
      alignment_groups:       AlignmentGroup.count,
      pericopes:              Pericope.count,
      versification_mappings: VersificationMapping.count
    }
  end
end
