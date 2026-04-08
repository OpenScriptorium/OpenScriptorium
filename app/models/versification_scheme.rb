class VersificationScheme < ApplicationRecord
  # Crosswire SWORD-style versification (v11n) schemes. We never invent
  # ad-hoc mappings — defer to Crosswire's published tables.
  has_many :canonical_works, dependent: :restrict_with_error
  has_many :works, foreign_key: :default_versification_scheme_id, dependent: :restrict_with_error
  has_many :outgoing_mappings,
           class_name: "VersificationMapping",
           foreign_key: :from_scheme_id,
           dependent: :destroy
  has_many :incoming_mappings,
           class_name: "VersificationMapping",
           foreign_key: :to_scheme_id,
           dependent: :destroy

  validates :code, presence: true, uniqueness: true,
                   format: { with: /\A[A-Z][A-Za-z0-9_]*\z/ }
  validates :display_name, presence: true

  def to_s
    code
  end
end
