import { Controller } from "@hotwired/stimulus"

// Toggles the search filter drawer open/closed.
export default class extends Controller {
  static targets = ["drawer"]

  toggle() {
    this.drawerTarget.classList.toggle("hidden")
  }
}
