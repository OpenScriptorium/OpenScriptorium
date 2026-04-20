class AddMissingPassageAliasNames < ActiveRecord::Migration[8.1]
  def up
    # Add commonly-searched alias variants that are missing from the JSON data.
    # These supplement the base import (passage_aliases_importer reads from
    # tmp/passage_aliases/*.json which has also been updated).
    #
    # The importer does wipe-and-reload, so on next full import these will be
    # re-created from the updated JSON. This migration ensures they exist NOW
    # without requiring a full re-import.

    now = Time.current

    additions = {
      # "Wheat and Tares" — existing alias uses "Wheat and the Tares"
      "Wheat and the Tares" => ["Wheat and Tares"],
      # "Marriage Feast" — existing alias uses "Parable of the Wedding Feast"
      "Parable of the Wedding Feast" => ["Marriage Feast", "Parable of the Marriage Feast"],
      # "Solomon's Judgment" — existing alias uses "Judgment of Solomon"
      "Judgment of Solomon" => ["Solomon's Judgment"]
    }

    additions.each do |existing_name, new_names|
      # Find the passage_alias through an existing name
      existing = PassageAliasName.find_by("LOWER(name) = LOWER(?)", existing_name)
      next unless existing

      new_names.each do |name|
        next if PassageAliasName.exists?(passage_alias_id: existing.passage_alias_id, name: name)
        PassageAliasName.create!(
          passage_alias_id: existing.passage_alias_id,
          name: name,
          locale: "en",
          created_at: now,
          updated_at: now
        )
      end
    end
  end

  def down
    %w[Wheat\ and\ Tares Marriage\ Feast Parable\ of\ the\ Marriage\ Feast Solomon's\ Judgment].each do |name|
      PassageAliasName.where(name: name).delete_all
    end
  end
end
