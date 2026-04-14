import { Controller } from "@hotwired/stimulus"

// Hamburger menu for mobile navigation.
export default class extends Controller {
  static targets = ["panel", "button", "iconOpen", "iconClose"]

  toggle() {
    const isOpen = !this.panelTarget.classList.contains("hidden")

    if (isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    this.iconOpenTarget.classList.add("hidden")
    this.iconCloseTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.panelTarget.classList.add("hidden")
    this.iconCloseTarget.classList.add("hidden")
    this.iconOpenTarget.classList.remove("hidden")
    this.buttonTarget.setAttribute("aria-expanded", "false")
  }

  // Close when navigating via Turbo
  disconnect() {
    this.close()
  }
}
