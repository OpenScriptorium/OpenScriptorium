// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"

// Word-study tooltip for original-language reader views. The reader
// renders Hebrew/Greek words as <span class="w" data-lemma-id="...">.
// Clicking any such span fetches /api/v1/lemmas/:id and shows a
// tooltip-style popover with a small arrow pointing at the word.
//
// Positioned absolute to document.body so it scrolls with the page
// content. Dismissed by Escape, outside click, or any window scroll
// (so it never gets stranded mid-screen as the reader scrolls).
export default class extends Controller {
  connect() {
    this.popover = document.createElement("div")
    this.popover.className = "word-popover"
    this.popover.setAttribute("role", "dialog")
    this.popover.setAttribute("aria-label", "Word study")
    this.popover.style.display = "none"
    document.body.appendChild(this.popover)

    this.element.addEventListener("click", this.onWordClick)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onKey)
    window.addEventListener("scroll", this.onScroll, { passive: true })
    document.addEventListener("turbo:before-render", this.close)
  }

  disconnect() {
    this.element.removeEventListener("click", this.onWordClick)
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("keydown", this.onKey)
    window.removeEventListener("scroll", this.onScroll)
    document.removeEventListener("turbo:before-render", this.close)
    this.popover.remove()
  }

  onWordClick = (event) => {
    const span = event.target.closest(".w-clickable[data-lemma-id]")
    if (!span) return
    event.preventDefault()
    this.openingClick = event
    this.openFor(span)
  }

  onDocumentClick = (event) => {
    if (this.openingClick === event) return
    if (this.popover.style.display === "none") return
    if (this.popover.contains(event.target)) return
    if (event.target.closest(".w-clickable")) return
    this.close()
  }

  onKey = (event) => {
    if (event.key === "Escape" && this.popover.style.display !== "none") {
      this.close()
    }
  }

  onScroll = () => {
    if (this.popover.style.display !== "none") this.close()
  }

  async openFor(anchor) {
    this.anchor = anchor
    const lemmaId = anchor.dataset.lemmaId

    this.popover.innerHTML = `<div class="word-popover-body"><div class="word-popover-loading">Loading…</div></div><div class="word-popover-arrow"></div>`
    this.popover.style.display = "block"
    this.position()

    try {
      const res = await fetch(`/api/v1/lemmas/${lemmaId}`, {
        headers: { "Accept": "application/json" }
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.json()
      if (this.popover.style.display === "none" || this.anchor !== anchor) return
      this.popover.innerHTML =
        `<div class="word-popover-body">${this.bodyHtml(data, anchor)}</div>` +
        `<div class="word-popover-arrow"></div>`
      this.position()
    } catch (err) {
      this.popover.innerHTML =
        `<div class="word-popover-body"><div class="word-popover-error">Couldn’t load lemma (${esc(err.message)})</div></div>` +
        `<div class="word-popover-arrow"></div>`
      this.position()
    }
  }

  close = () => {
    this.popover.style.display = "none"
    this.anchor = null
  }

  bodyHtml(data, anchor) {
    const lang = data.language || ""
    const strongs = anchor.dataset.strongs || ""
    const morph = anchor.dataset.morph || ""
    const surface = anchor.textContent || ""
    // Form-specific attrs set by reader_helper#word_span:
    //   data-translit  → transliteration of THIS inflected surface
    //   data-parsing   → humanized parsing prose ("Verb, Aorist Active Indicative 3rd Singular")
    const surfaceTranslit = anchor.dataset.translit || ""
    const parsing = anchor.dataset.parsing || ""

    const meta = []
    if (strongs) meta.push(`Strong&rsquo;s ${esc(strongs)}`)
    if (data.frequency != null) meta.push(`${data.frequency} occurrences`)
    // Show the raw morph code only if we couldn't humanize it — otherwise
    // it just duplicates the parsing line.
    if (morph && !parsing) meta.push(esc(morph))

    const lemmaBits = []
    if (data.lemma) lemmaBits.push(`<a class="word-popover-lemma" lang="${esc(lang)}" href="/lemmas/${esc(data.id)}">${esc(data.lemma)}</a>`)
    if (data.part_of_speech) lemmaBits.push(`<span class="word-popover-pos">${esc(data.part_of_speech)}</span>`)

    return `
      <div class="word-popover-header">
        <span class="word-popover-surface" lang="${esc(lang)}">${esc(surface)}</span>
        ${surfaceTranslit ? `<span class="word-popover-surface-translit">${esc(surfaceTranslit)}</span>` : ""}
      </div>
      ${parsing ? `<div class="word-popover-parsing">${esc(parsing)}</div>` : ""}
      <div class="word-popover-lemma-row"><span class="word-popover-arrow-glyph" aria-hidden="true">↳</span> ${lemmaBits.join(" &middot; ")}</div>
      ${data.transliteration && data.transliteration !== surfaceTranslit ? `<div class="word-popover-translit">${esc(data.transliteration)}</div>` : ""}
      ${data.primary_gloss ? `<div class="word-popover-gloss">${esc(data.primary_gloss)}</div>` : ""}
      ${meta.length ? `<div class="word-popover-meta">${meta.join(" &middot; ")}</div>` : ""}
      <div class="word-popover-footer">
        <a class="word-popover-more" href="/lemmas/${esc(data.id)}">Word study →</a>
      </div>
    `
  }

  // Anchor below the word's *page-relative* rect (rect + window.scrollY).
  // position:absolute on body so the popover scrolls naturally with the
  // text. Flips above when the word is too close to the viewport bottom;
  // the arrow flips with it. Horizontal: clamp into the viewport with a
  // 12px margin and shift the arrow to stay aligned with the word.
  position() {
    if (!this.anchor) return
    const rect = this.anchor.getBoundingClientRect()
    const margin = 12
    const gap = 10               // space between word and popover
    const arrowHalf = 7          // half of the arrow square's side

    this.popover.style.position = "absolute"
    this.popover.style.visibility = "hidden"
    this.popover.style.top = "0px"
    this.popover.style.left = "0px"
    this.popover.dataset.placement = "below"

    const popRect = this.popover.getBoundingClientRect()
    const viewportH = document.documentElement.clientHeight
    const viewportW = document.documentElement.clientWidth

    // Decide vertical placement based on viewport room.
    const roomBelow = viewportH - rect.bottom
    const roomAbove = rect.top
    let placement = "below"
    let top
    if (roomBelow < popRect.height + gap + margin && roomAbove > popRect.height + gap + margin) {
      placement = "above"
      top = rect.top + window.scrollY - popRect.height - gap
    } else {
      top = rect.bottom + window.scrollY + gap
    }
    this.popover.dataset.placement = placement

    // Horizontal: align popover left with word left, then clamp.
    let left = rect.left + window.scrollX
    const minLeft = window.scrollX + margin
    const maxLeft = window.scrollX + viewportW - popRect.width - margin
    if (left > maxLeft) left = maxLeft
    if (left < minLeft) left = minLeft

    // Arrow: align with the *word* center, but clamp inside the popover
    // so it never escapes the rounded corners.
    const arrowMin = 14
    const arrowMax = popRect.width - 14
    const wordCenterX = rect.left + rect.width / 2 + window.scrollX
    let arrowLeft = wordCenterX - left
    if (arrowLeft < arrowMin) arrowLeft = arrowMin
    if (arrowLeft > arrowMax) arrowLeft = arrowMax

    this.popover.style.top = `${top}px`
    this.popover.style.left = `${left}px`
    this.popover.style.setProperty("--word-popover-arrow-x", `${arrowLeft - arrowHalf}px`)
    this.popover.style.visibility = "visible"
  }
}

function esc(s) {
  const div = document.createElement("div")
  div.textContent = s == null ? "" : String(s)
  return div.innerHTML
}
// @license-end
