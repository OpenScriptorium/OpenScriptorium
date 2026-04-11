// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"

// Client-side multi-select filter for the /works page. Each work row
// carries data attributes (data-language, data-traditions,
// data-work-type, data-features). All filter dimensions use checkbox
// badges; within a dimension, selections use OR logic (any match);
// between dimensions, AND logic (all must pass).
//
// Tradition prefix matching: selecting "χ" matches any tradition
// starting with "χ" (χ-orthodox, χ-catholic, etc.). Same for "ש".
export default class extends Controller {
  static targets = ["row", "empty", "summary", "badge", "liveRegion"]

  connect() {
    this._isConnect = true
    this.apply()
    this._isConnect = false
  }

  apply() {
    const languages  = this.checkedValues("languages[]")
    const traditions = this.checkedValues("traditions[]")
    const types      = this.checkedValues("types[]")
    const features   = this.checkedValues("features[]")

    let visibleCount = 0

    this.rowTargets.forEach((row) => {
      const rowLang   = row.dataset.language || ""
      const rowTrads  = (row.dataset.traditions || "").split(" ").filter(Boolean)
      const rowType   = row.dataset.workType || ""
      const rowFeats  = (row.dataset.features || "").split(" ").filter(Boolean)

      const matches =
        this.matchesOr(languages, [rowLang])                    &&
        this.matchesTraditions(traditions, rowTrads)             &&
        this.matchesOr(types, [rowType])                        &&
        features.every((f) => rowFeats.includes(f))

      row.hidden = !matches
      if (matches) visibleCount++
    })

    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = visibleCount > 0
    }

    if (this.hasLiveRegionTarget) {
      this.liveRegionTarget.textContent = visibleCount > 0
        ? "Showing " + visibleCount + " works"
        : "No works match these filters"
    }

    this.refreshBadgeStyles()
    this.refreshSummary(languages, traditions, types, features)
    this.syncUrl(languages, traditions, types, features)
  }

  clear(event) {
    event.preventDefault()
    this.element.querySelectorAll("input[type='checkbox']").forEach((c) => { c.checked = false })
    this.apply()
  }

  // ----------------------------------------------------------------

  checkedValues(name) {
    return Array.from(
      this.element.querySelectorAll(`input[name='${name}']:checked`)
    ).map((c) => c.value)
  }

  // OR match: if no filters selected, everything passes. If any
  // selected, at least one of the row's values must be in the set.
  matchesOr(selected, rowValues) {
    if (selected.length === 0) return true
    return selected.some((s) => rowValues.includes(s))
  }

  // Tradition matching with prefix expansion: selecting "χ" matches
  // any tradition starting with "χ", and selecting "ש" matches any
  // tradition starting with "ש".
  matchesTraditions(selected, rowTrads) {
    if (selected.length === 0) return true
    return selected.some((s) => {
      if (s === "χ" || s === "ש") {
        return rowTrads.some((t) => t.startsWith(s))
      }
      return rowTrads.includes(s)
    })
  }

  refreshBadgeStyles() {
    if (!this.hasBadgeTarget) return
    this.badgeTargets.forEach((badge) => {
      const input = badge.querySelector("input[type='checkbox']")
      if (!input) return
      badge.classList.toggle("is-active", input.checked)
    })
  }

  refreshSummary(languages, traditions, types, features) {
    if (!this.hasSummaryTarget) return
    const parts = [...languages, ...traditions, ...types, ...features]
    if (parts.length === 0) {
      this.summaryTarget.textContent = ""
      this.summaryTarget.hidden = true
    } else {
      this.summaryTarget.textContent = `(${parts.join(", ")})`
      this.summaryTarget.hidden = false
    }
  }

  syncUrl(languages, traditions, types, features) {
    const url = new URL(window.location.href)
    const params = url.searchParams

    ;["languages[]", "traditions[]", "types[]", "features[]"].forEach((k) => {
      params.delete(k)
      params.delete(k.replace("[]", "%5B%5D"))
    })

    languages.forEach((v)  => params.append("languages[]", v))
    traditions.forEach((v) => params.append("traditions[]", v))
    types.forEach((v)      => params.append("types[]", v))
    features.forEach((v)   => params.append("features[]", v))

    const next = url.pathname + (params.toString() ? `?${params.toString()}` : "")
    if (this._isConnect) return
    window.history.replaceState(null, "", next)
  }
}
// @license-end
