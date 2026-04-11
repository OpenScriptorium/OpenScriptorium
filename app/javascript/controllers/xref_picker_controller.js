// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"
import * as Turbo from "@hotwired/turbo-rails"

// Cross-reference dataset picker. Each checkbox value is a dataset
// slug; the controller maintains the active set in the
// `xref_datasets` cookie (comma-separated). Toggling reloads the
// page so the inline xrefs in each verse re-render with the new
// dataset selection. The cookie is persistent (1 year) and
// path-scoped to the whole site.
//
// Toggling reloads the page via Turbo.visit with action "replace"
// so it doesn't add a history entry — xrefs render inline below
// every verse, so there's no single frame to swap.
export default class extends Controller {
  toggle(event) {
    const details = this.element.querySelector("details")
    const checked = Array.from(
      details.querySelectorAll("input[type='checkbox']:checked")
    ).map((c) => c.value)

    this.setCookie("xref_datasets", checked.join(","), 365)
    Turbo.visit(window.location.href, { action: "replace" })
  }

  toggleApparatus(event) {
    const on = event.target.checked
    this.setCookie("apparatus", on ? "on" : "", 365)
    // Toggle visibility of all apparatus entries on the page
    document.querySelectorAll(".verse-apparatus").forEach(el => {
      el.classList.toggle("hidden", !on)
    })
  }

  setCookie(name, value, days) {
    const expires = new Date(Date.now() + days * 24 * 60 * 60 * 1000).toUTCString()
    const encoded = encodeURIComponent(value)
    document.cookie = `${name}=${encoded}; expires=${expires}; path=/; samesite=lax`
  }
}
// @license-end
