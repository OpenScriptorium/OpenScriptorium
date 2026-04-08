class AddBookKeyToCanonicalWorks < ActiveRecord::Migration[8.1]
  # The slug column on canonical_works is unique, but we want multiple
  # canonical_works to coexist for the same conceptual book under
  # different versification schemes. For example:
  #
  #   slug: "psalms",     book_key: "psalms",  scheme: KJV
  #   slug: "psalms-lxx", book_key: "psalms",  scheme: LXX
  #
  # The reader URL uses book_key (so /rahlfs-lxx/psalms/9 works) and
  # the controller picks the canonical_work whose book_key matches
  # AND has work_units belonging to the current Work.
  def change
    add_column :canonical_works, :book_key, :string
    add_index  :canonical_works, :book_key

    # Backfill: for every existing row, book_key = slug. Subsequent
    # LXX-specific rows will share book_key with their KJV equivalents.
    reversible do |dir|
      dir.up do
        execute "UPDATE canonical_works SET book_key = slug WHERE book_key IS NULL"
        change_column_null :canonical_works, :book_key, false
      end
    end
  end
end
