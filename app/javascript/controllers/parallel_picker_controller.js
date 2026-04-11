// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"

// Per-column work picker for the parallel reader.
//
// The view emits one <select.parallel-col> per column (in column order),
// plus a final "+ Add column" <select> with a blank first option. Any
// change to any select reads all column values left-to-right and
// navigates to the same path with an updated `?works=` parameter.
//
// Special select values:
//   ""           — empty slot (the "+ Add column" affordance, ignored
//                  unless the user picks a real work)
//   "__remove__" — removes this column on the next navigation
export default class extends Controller {
  update(event) {
    const selects = Array.from(this.element.querySelectorAll("select.parallel-col"))
    const slugs = selects
      .map(s => s.value)
      .filter(v => v && v !== "__remove__")

    // Don't navigate to an empty parallel view.
    if (slugs.length === 0) return

    // De-dupe in case the user picked the same work in two columns,
    // preserving the leftmost occurrence.
    const seen = new Set()
    const unique = []
    for (const s of slugs) {
      if (!seen.has(s)) { seen.add(s); unique.push(s) }
    }

    const url = new URL(window.location.href)
    url.searchParams.delete("works")
    url.searchParams.delete("works[]")
    url.searchParams.set("works", unique.join(","))
    window.location.assign(url.pathname + "?" + url.searchParams.toString())
  }
}
// @license-end
