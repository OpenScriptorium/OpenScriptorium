// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"

// Builds a reader URL from a free-form passage spec entered in the input,
// then navigates to it. Accepted forms (matches our Rails routes):
//
//   3            → /:work/:book/3                 (whole chapter)
//   3:16         → /:work/:book/3/16              (single verse)
//   3:16-21      → /:work/:book/3/16-21           (intra-chapter range)
//   1:1-2:3      → /:work/:book/1.1-2.3           (cross-chapter range)
//
// Whitespace and a trailing semicolon are tolerated. Anything that doesn't
// match a known pattern shows a tiny error message instead of navigating.
export default class extends Controller {
  static targets = ["input"]
  static values  = { work: String, book: String }

  go(event) {
    event.preventDefault()
    const raw  = this.inputTarget.value.trim().replace(/\s+/g, "")
    if (raw === "") return

    const path = this.buildPath(raw)
    if (path) {
      window.location.assign(path)
    } else {
      this.flash(`Couldn't parse "${raw}"`)
    }
  }

  buildPath(spec) {
    const base = `/${this.workValue}/${this.bookValue}`

    // Cross-chapter range: 1:1-2:3
    let m = spec.match(/^(\d+):(\d+)-(\d+):(\d+)$/)
    if (m) {
      const [_, a, b, c, d] = m
      return `${base}/${a}.${b}-${c}.${d}`
    }

    // Intra-chapter range: 3:16-21
    m = spec.match(/^(\d+):(\d+)-(\d+)$/)
    if (m) {
      const [_, ch, from, to] = m
      return `${base}/${ch}/${from}-${to}`
    }

    // Single verse: 3:16
    m = spec.match(/^(\d+):(\d+)$/)
    if (m) {
      const [_, ch, v] = m
      return `${base}/${ch}/${v}`
    }

    // Whole chapter: 3
    m = spec.match(/^(\d+)$/)
    if (m) {
      return `${base}/${m[1]}`
    }

    return null
  }

  flash(message) {
    this.inputTarget.setCustomValidity(message)
    this.inputTarget.reportValidity()
    setTimeout(() => this.inputTarget.setCustomValidity(""), 2000)
  }
}
// @license-end
