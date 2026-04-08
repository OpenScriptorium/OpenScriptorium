class AddUserProfileFields < ActiveRecord::Migration[8.1]
  # Extends the Rails 8 native auth User model with display info,
  # role-based authorization, and an invitation/preferences setup.
  def change
    change_table :users do |t|
      t.string  :display_name
      t.text    :bio
      t.string  :role,                null: false, default: "visitor"
        # visitor, contributor, moderator, admin
      t.references :invited_by_user,  foreign_key: { to_table: :users }
      t.datetime :invited_at
      t.datetime :email_confirmed_at
      t.jsonb    :preferences,        null: false, default: {}
        # font choice, custom font URL, hebrew display toggles,
        # versification scheme, locale, theme
    end

    add_index :users, :role
  end
end
