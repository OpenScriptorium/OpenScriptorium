class CreateInvitations < ActiveRecord::Migration[8.1]
  # Invite codes used during the invite-only phase. Admins generate them,
  # the redeemer enters the code on signup.
  def change
    create_table :invitations do |t|
      t.string     :code,            null: false
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.references :used_by_user,    foreign_key: { to_table: :users }
      t.datetime   :used_at
      t.datetime   :expires_at
      t.text       :notes
      t.timestamps
    end

    add_index :invitations, :code, unique: true
    add_index :invitations, :used_at
  end
end
