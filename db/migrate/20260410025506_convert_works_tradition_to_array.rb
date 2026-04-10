class ConvertWorksTraditionToArray < ActiveRecord::Migration[8.1]
  # Convert works.tradition from a single string to a string array so
  # multi-tradition works (Rahlfs: orthodox + academic, Philo: jewish +
  # patristic) are representable. Remaps existing ad-hoc values to the
  # standardized taxonomy: jewish, catholic, orthodox, protestant,
  # patristic, academic.
  def up
    # 1) Add the new array column
    add_column :works, :traditions, :string, array: true, default: []

    # 2) Migrate existing data
    remap = {
      "jewish"           => ["jewish"],
      "jewish_english"   => ["jewish"],
      "septuagint"       => ["orthodox", "academic"],
      "lxx_translation"  => ["orthodox"],
      "byzantine_text"   => ["orthodox"],
      "critical_text"    => ["academic"],
      "kjv"              => ["protestant"],
      "modern_protestant" => ["protestant"],
      "luther"           => ["protestant"]
    }

    execute <<~SQL
      UPDATE works SET traditions = ARRAY[]::varchar[] WHERE tradition IS NULL;
    SQL

    remap.each do |old_val, new_vals|
      array_literal = "{#{new_vals.join(',')}}"
      execute <<~SQL
        UPDATE works SET traditions = '#{array_literal}' WHERE tradition = '#{old_val}';
      SQL
    end

    # 3) Index for GIN array queries
    add_index :works, :traditions, using: :gin

    # 4) Drop the old scalar column
    remove_column :works, :tradition
  end

  def down
    add_column :works, :tradition, :string
    # Best-effort reverse: take the first element
    execute <<~SQL
      UPDATE works SET tradition = traditions[1];
    SQL
    remove_index :works, :traditions
    remove_column :works, :traditions
  end
end
