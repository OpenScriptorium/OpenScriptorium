import { Controller } from "@hotwired/stimulus"

// Client-side filter for the /works page. Each work row carries
// data attributes (data-language, data-tradition, data-work-type,
// data-features) — this controller reads the form state on every
// change and toggles each row's `hidden` attribute. The URL is
// updated with `history.replaceState` so the filtered view stays
// shareable, but no server roundtrip happens.
//
// Targets:
//   - row    : every work `<li>` in the list (one per work)
//   - empty  : the "no works match" message
//   - summary: optional element where the active-filter summary
//              text is rendered (the disclosure label)
//   - badge  : optional feature-checkbox label, toggled `is-active`
//              when its checkbox is checked
//
// Inputs the controller listens to (via the `change` and `input`
// actions in the markup):
//   - select[name="language"]
//   - select[name="tradition"]
//   - select[name="type"]
//   - input[name="features[]"] (multiple checkboxes)
//
// Clear button: `data-action="works-filter#clear"` resets all
// inputs and unhides every row.
export default class extends Controller {
  static targets = ["row", "empty", "summary", "badge", "details"]

  connect() {
    this.apply()
  }

  apply() {
    const language  = this.selectedValue("language")
    const tradition = this.selectedValue("tradition")
    const type      = this.selectedValue("type")
    const features  = this.selectedFeatures()

    let visibleCount = 0

    this.rowTargets.forEach((row) => {
      const rowLang   = row.dataset.language || ""
      const rowTrads  = (row.dataset.traditions || "").split(" ").filter(Boolean)
      const rowType   = row.dataset.workType || ""
      const rowFeats  = (row.dataset.features || "").split(" ").filter(Boolean)

      const matches =
        (!language  || rowLang === language)       &&
        (!tradition || rowTrads.includes(tradition)) &&
        (!type      || rowType === type)           &&
        features.every((f) => rowFeats.includes(f))

      row.hidden = !matches
      if (matches) visibleCount++
    })

    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = visibleCount > 0
    }

    this.refreshBadgeStyles(features)
    this.refreshSummary(language, tradition, type, features)
    this.syncUrl(language, tradition, type, features)
  }

  // Reset every input and re-apply (everything visible, no URL params).
  clear(event) {
    event.preventDefault()
    this.element.querySelectorAll("select").forEach((s) => { s.value = "" })
    this.element.querySelectorAll("input[name='features[]']").forEach((c) => { c.checked = false })
    this.apply()
  }

  // ----------------------------------------------------------------

  selectedValue(name) {
    const el = this.element.querySelector(`select[name="${name}"]`)
    return el ? el.value : ""
  }

  selectedFeatures() {
    return Array.from(
      this.element.querySelectorAll("input[name='features[]']:checked")
    ).map((c) => c.value)
  }

  refreshBadgeStyles(features) {
    if (!this.hasBadgeTarget) return
    this.badgeTargets.forEach((badge) => {
      const input = badge.querySelector("input[type='checkbox']")
      if (!input) return
      badge.classList.toggle("is-active", input.checked)
    })
  }

  refreshSummary(language, tradition, type, features) {
    if (!this.hasSummaryTarget) return
    const parts = [language, tradition, type, ...features].filter(Boolean)
    if (parts.length === 0) {
      this.summaryTarget.textContent = ""
      this.summaryTarget.hidden = true
    } else {
      this.summaryTarget.textContent = `(${parts.join(", ")})`
      this.summaryTarget.hidden = false
    }
  }

  syncUrl(language, tradition, type, features) {
    const url = new URL(window.location.href)
    const params = url.searchParams

    // Wipe the current state for these keys, then re-add what's set.
    ;["language", "tradition", "type"].forEach((k) => params.delete(k))
    params.delete("features[]")
    params.delete("features%5B%5D")

    if (language)  params.set("language",  language)
    if (tradition) params.set("tradition", tradition)
    if (type)      params.set("type",      type)
    features.forEach((f) => params.append("features[]", f))

    const next = url.pathname + (params.toString() ? `?${params.toString()}` : "")
    window.history.replaceState(null, "", next)
  }
}
