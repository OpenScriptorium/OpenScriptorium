class CreateSyntaxNodes < ActiveRecord::Migration[8.1]
  def change
    create_table :syntax_nodes do |t|
      t.references :work, null: false, foreign_key: true
      t.references :work_unit, null: false, foreign_key: true
      t.references :parent, foreign_key: { to_table: :syntax_nodes }
      t.column     :path, :ltree, null: false
      t.string     :node_class, null: false   # "cl", "ph", "pp", "np", "vp"
      t.string     :node_type                 # clause: "NC","VC","Way0"; phrase: "NP","VP","PP"
      t.string     :clause_type               # Greek cltype: "Verbless","Declarative", etc.
      t.string     :rule                      # syntax rule: "PP-V-S-O", "NPofNP", etc.
      t.string     :role                      # "s","p","o","io","c","a","v","pp" etc.
      t.integer    :start_position
      t.integer    :end_position
      t.integer    :depth, default: 0
      t.bigint     :import_run_id
      t.timestamps

      t.index :path, using: :gist
      t.index [:work_unit_id, :node_class]
      t.index [:node_class, :role]
      t.index [:node_class, :node_type]
      t.index :import_run_id
    end

    add_reference :words, :syntax_node, foreign_key: true, index: true
  end
end
