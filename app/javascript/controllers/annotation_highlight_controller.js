import { Controller } from "@hotwired/stimulus"

// Pairs anchor phrases in the verse text with their margin entries on
// hover. The chapter view tags both sides with matching `data-annot`
// attributes scoped to a `.verse-row` wrapper; this controller listens
// for mouseenter/mouseleave on any data-annot element and toggles the
// `annot-active` class on every other element with the same data-annot
// inside the same verse-row.
//
// `.verse-row` uses `display: contents` to flatten its <p> and <aside>
// directly into the parent grid, but `.closest()` still walks the DOM
// tree as if display were normal — display: contents only affects box
// rendering, not the tree shape — so the row scoping works.
export default class extends Controller {
  connect() {
    this.elements = this.element.querySelectorAll("[data-annot]")
    this.elements.forEach(el => {
      el.addEventListener("mouseenter", this.handleEnter)
      el.addEventListener("mouseleave", this.handleLeave)
    })
  }

  disconnect() {
    this.elements.forEach(el => {
      el.removeEventListener("mouseenter", this.handleEnter)
      el.removeEventListener("mouseleave", this.handleLeave)
    })
  }

  handleEnter = (event) => {
    const target = event.currentTarget
    const annot = target.dataset.annot
    if (annot == null) return
    const row = target.closest(".verse-row") || this.element
    row.querySelectorAll(`[data-annot="${annot}"]`).forEach(m =>
      m.classList.add("annot-active")
    )
  }

  handleLeave = (event) => {
    const target = event.currentTarget
    const annot = target.dataset.annot
    if (annot == null) return
    const row = target.closest(".verse-row") || this.element
    row.querySelectorAll(`[data-annot="${annot}"]`).forEach(m =>
      m.classList.remove("annot-active")
    )
  }
}
