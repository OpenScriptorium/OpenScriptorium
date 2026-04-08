# Default licenses for the corpus. Every Work MUST have a license_id.
# All licenses below meet the FSF/RMS / OSI / Free Cultural Works
# definitions and are safe for redistribution.
LICENSES = [
  { name: "Public Domain",
    spdx_id: "CC-PDDC",
    url: "https://creativecommons.org/share-your-work/public-domain/pdm/",
    attribution_required: false,
    attribution_template: nil,
    description: "No copyright restrictions. Most works published before 1929 (or whose author has been dead longer than the local copyright term) are public domain." },

  { name: "CC0 1.0 Universal",
    spdx_id: "CC0-1.0",
    url: "https://creativecommons.org/publicdomain/zero/1.0/",
    attribution_required: false,
    description: "Public-domain dedication." },

  { name: "Creative Commons Attribution 4.0",
    spdx_id: "CC-BY-4.0",
    url: "https://creativecommons.org/licenses/by/4.0/",
    attribution_required: true,
    attribution_template: "%{title} by %{author}, used under CC BY 4.0.",
    description: "Free use with attribution required." },

  { name: "Creative Commons Attribution-ShareAlike 4.0",
    spdx_id: "CC-BY-SA-4.0",
    url: "https://creativecommons.org/licenses/by-sa/4.0/",
    attribution_required: true,
    attribution_template: "%{title} by %{author}, used under CC BY-SA 4.0.",
    description: "Free use with attribution; derivatives must use the same license." },

  { name: "Berean Standard Bible License",
    spdx_id: nil,
    url: "https://berean.bible/terms.htm",
    attribution_required: false,
    description: "The Berean Standard Bible (BSB) is released into the public domain. No restrictions." },
].freeze

LICENSES.each do |attrs|
  license = License.find_or_initialize_by(name: attrs[:name])
  license.assign_attributes(attrs)
  license.save!
end

puts "  licenses: #{License.count}"
