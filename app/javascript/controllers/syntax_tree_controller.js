import { Controller } from "@hotwired/stimulus"

// Renders a nested syntax tree for a verse from the Macula data.
// Usage: <div data-controller="syntax-tree" data-syntax-tree-url-value="/api/v1/syntax/wlc/Gen/1/1">
export default class extends Controller {
  static values = { url: String }

  connect() {
    if (this.urlValue) {
      this.load()
    }
  }

  async load() {
    try {
      const response = await fetch(this.urlValue)
      if (!response.ok) return
      const data = await response.json()
      this.render(data.tree)
    } catch (e) {
      this.element.innerHTML = `<p class="text-sm text-[var(--color-muted)]">Syntax data unavailable</p>`
    }
  }

  render(tree) {
    if (!tree || tree.length === 0) {
      this.element.innerHTML = `<p class="text-sm text-[var(--color-muted)]">No syntax data for this verse</p>`
      return
    }
    this.element.innerHTML = ""
    const container = document.createElement("div")
    container.className = "syntax-tree font-serif text-sm leading-relaxed"
    tree.forEach(node => container.appendChild(this.renderNode(node)))
    this.element.appendChild(container)
  }

  renderNode(node) {
    const el = document.createElement("div")
    el.className = `syntax-node syntax-${node.class} depth-${node.depth}`
    el.style.marginLeft = `${node.depth * 12}px`
    el.style.borderLeft = `3px solid ${this.roleColor(node.role)}`
    el.style.paddingLeft = "8px"
    el.style.marginBottom = "2px"
    el.style.paddingTop = "2px"
    el.style.paddingBottom = "2px"

    // Label
    const label = document.createElement("span")
    label.className = "syntax-label text-xs font-sans font-medium uppercase tracking-wider"
    label.style.color = this.roleColor(node.role)

    const parts = []
    if (node.class === "cl") parts.push("clause")
    else if (node.class) parts.push(node.class.toUpperCase())
    if (node.role_label) parts.push(node.role_label)
    if (node.type) parts.push(`[${node.type}]`)
    if (node.clause_type) parts.push(`[${node.clause_type}]`)
    if (node.rule) parts.push(`(${node.rule})`)
    label.textContent = parts.join(" ")
    el.appendChild(label)

    // Words at this node level
    if (node.words && node.words.length > 0) {
      const wordsEl = document.createElement("span")
      wordsEl.className = "syntax-words ml-2"
      node.words.forEach(w => {
        const wordSpan = document.createElement("span")
        wordSpan.className = "syntax-word inline-block mx-0.5 cursor-help"
        wordSpan.style.borderBottom = `2px solid ${this.roleColor(w.role)}`

        const surface = document.createElement("span")
        surface.className = "text-base"
        surface.textContent = w.surface
        wordSpan.appendChild(surface)

        if (w.gloss) {
          const gloss = document.createElement("span")
          gloss.className = "text-xs text-[var(--color-muted)] ml-0.5"
          gloss.textContent = `(${w.gloss})`
          wordSpan.appendChild(gloss)
        }

        // Tooltip with full info
        const tooltip = [w.role_label, w.pos, w.lemma].filter(Boolean).join(" | ")
        if (tooltip) wordSpan.title = tooltip

        wordsEl.appendChild(wordSpan)
      })
      el.appendChild(wordsEl)
    }

    // Children
    if (node.children && node.children.length > 0) {
      node.children.forEach(child => {
        el.appendChild(this.renderNode(child))
      })
    }

    return el
  }

  roleColor(role) {
    const colors = {
      s: "#2563eb",    // blue — subject
      p: "#dc2626",    // red — predicate
      v: "#dc2626",    // red — verb (same as predicate)
      o: "#059669",    // green — object
      io: "#7c3aed",   // purple — indirect object
      c: "#d97706",    // amber — complement
      a: "#6b7280",    // gray — adjunct
      pp: "#0891b2",   // cyan — prepositional phrase
      adv: "#6b7280",  // gray — adverb
    }
    return colors[role] || "#9ca3af"
  }
}
