class AddTraditionsToPericopesAndWorks < ActiveRecord::Migration[8.1]
  # Pericope sets are tradition-specific — parashot belong to Jewish
  # synagogue practice, lectionaries belong to specific liturgical
  # calendars, BHS pericopes belong to the Hebrew text-critical
  # convention. Storing pericopes at the canonical layer is correct for
  # passage identity, but the reader needs to know which pericope sets
  # apply to the current work so it doesn't show parashot when someone
  # is reading the Vulgate.
  #
  # `pericopes.tradition` tags each pericope row with its tradition.
  # `works.pericope_traditions` is a string array declaring which
  # tradition tags this work participates in (a Hebrew Bible work like
  # WLC carries `[hebrew_textcritical, jewish_liturgical]`; Luther 1912
  # carries `[lutheran_lectionary]`; KJV carries `[]` since the KJV has
  # no pericope tradition baked in).
  def change
    add_column :pericopes, :tradition, :string
    add_index  :pericopes, :tradition

    add_column :works, :pericope_traditions, :string, array: true, default: []
    add_index  :works, :pericope_traditions, using: :gin
  end
end
