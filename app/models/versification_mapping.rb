class VersificationMapping < ApplicationRecord
  has_paper_trail

  belongs_to :from_scheme,        class_name: "VersificationScheme"
  belongs_to :from_canonical_ref, class_name: "CanonicalRef"
  belongs_to :to_scheme,          class_name: "VersificationScheme"
  belongs_to :to_canonical_ref,   class_name: "CanonicalRef"

  TYPES = %w[exact partial split merge missing].freeze

  validates :mapping_type, inclusion: { in: TYPES }
end
