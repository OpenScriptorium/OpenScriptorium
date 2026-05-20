class NullEmptyWordStrongsNumbers < ActiveRecord::Migration[8.1]
  # KJV's parse_strongs_text emitted Word rows with strongs_number = ""
  # for translator-supplied editorial English (italicized words in 1611:
  # "him.", "what have we?", "unto thee."). These words have no
  # underlying Hebrew/Greek source so they shouldn't carry a Strong's at
  # all — empty string was a bug that polluted "no-lemma-but-has-Strong's"
  # audits and risked future code treating "" as a real value.
  #
  # The KJV importer has been corrected to write NULL going forward. This
  # migration cleans the existing rows.
  def up
    execute <<~SQL
      UPDATE words SET strongs_number = NULL WHERE strongs_number = '';
    SQL
  end

  def down
    # No going back — we never want empty-string Strong's again.
  end
end
