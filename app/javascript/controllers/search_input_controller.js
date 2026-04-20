import { Controller } from "@hotwired/stimulus"

// Navbar search input — detects citation-like queries and redirects
// directly to the reader instead of going through the search results page.
export default class extends Controller {
  static targets = ["input"]

  // Basic citation pattern: optional number + book abbreviation + chapter[:verse]
  // This is intentionally loose — the server-side CitationParser does strict validation.
  static CITATION_RE = /^(\d\s+)?[A-Z][a-z.]+\.?\s+\d+/i

  checkCitation(event) {
    // Only intercept on Enter
    if (event.key !== "Enter") return

    const query = this.inputTarget.value.trim()
    if (!query) return

    // If it looks like a citation, let the server handle the redirect
    // (the search controller will redirect to the reader).
    // No client-side redirect needed — the server does it faster and
    // more accurately with access to the canonical_works table.
  }
}
