# Open Scriptorium seeds. Idempotent — safe to re-run.
# Each individual seed file is in db/seeds/ and is responsible for its
# own idempotency. Order matters: schemes must be loaded before canonical
# works, etc.

puts "Seeding Open Scriptorium..."

%w[
  versification_schemes
  licenses
  canonical_works
].each do |name|
  load Rails.root.join("db/seeds/#{name}.rb")
end

puts "Done."
