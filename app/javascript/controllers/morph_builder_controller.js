import { Controller } from "@hotwired/stimulus"

// Builds a morphological code pattern from dropdown selections.
// Used on the advanced search page.
export default class extends Controller {
  static targets = ["pos", "tense", "voice", "mood", "person", "number", "output"]

  build() {
    const parts = [
      this.posTarget.value,
      this.tenseTarget.value,
      this.voiceTarget.value,
      this.moodTarget.value,
      this.personTarget.value,
      this.numberTarget.value
    ]

    const code = `morph:${parts.join("-")}`
    this.outputTarget.textContent = code

    // Also set the main query input if it exists
    const queryInput = document.getElementById("q")
    if (queryInput && this._anySelected(parts)) {
      queryInput.value = code
    }
  }

  _anySelected(parts) {
    return parts.some(p => p !== "*")
  }
}
