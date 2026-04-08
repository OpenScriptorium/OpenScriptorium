class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  # Convenience class methods so callers can do:
  #   Setting[:public_reading_enabled]
  #   Setting[:public_reading_enabled] = true
  def self.[](key)
    find_by(key: key.to_s)&.value
  end

  def self.[]=(key, value)
    record = find_or_initialize_by(key: key.to_s)
    record.value = value.to_s
    record.save!
    value
  end

  def self.boolean(key)
    self[key].to_s == "true"
  end
end
