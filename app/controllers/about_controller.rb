class AboutController < ApplicationController
  allow_unauthenticated_access only: [:architecture, :schema, :principles]

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
  end
end
