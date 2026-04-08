class VariantUnit < ApplicationRecord
  belongs_to :canonical_ref
  belongs_to :base_reading, class_name: "Reading", optional: true
  belongs_to :import_run, optional: true

  has_many :readings, dependent: :destroy

  VARIANT_TYPES = %w[
    substitution
    omission
    addition
    transposition
    orthographic
    other
  ].freeze

  validates :variant_type, inclusion: { in: VARIANT_TYPES, allow_nil: true }
end
