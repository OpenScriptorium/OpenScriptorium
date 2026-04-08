class VariantUnit < ApplicationRecord
  belongs_to :canonical_ref
  belongs_to :base_reading, class_name: "Reading", optional: true

  has_many :readings, dependent: :destroy
end
