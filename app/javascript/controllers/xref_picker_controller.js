import { Controller } from "@hotwired/stimulus"

// Cross-reference dataset picker. Each checkbox value is a dataset
// slug; the controller maintains the active set in the
// `xref_datasets` cookie (comma-separated). Toggling reloads the
// page so the inline xrefs in each verse re-render with the new
// dataset selection. The cookie is persistent (1 year) and
// path-scoped to the whole site.
//
// We deliberately do a full reload rather than a Turbo Frame
// refresh — xrefs render inline below every verse, scattered through
// the prose, so there's no single frame to swap. A reload is the
// simplest way to keep the picker in sync with the rendered prose
// without coupling the reader views to a frame layout.
export default class extends Controller {
  toggle(event) {
    const details = this.element.querySelector("details")
    const checked = Array.from(
      details.querySelectorAll("input[type='checkbox']:checked")
    ).map((c) => c.value)

    this.setCookie("xref_datasets", checked.join(","), 365)
    window.location.reload()
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
