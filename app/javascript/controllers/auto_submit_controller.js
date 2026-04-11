// @license magnet:?xt=urn:btih:b8999bbaf509c08d127678643c515b9ab0836bae&dn=ISC.txt ISC
import { Controller } from "@hotwired/stimulus"

// Submits the form whenever an input fires its action. Used by the
// works index filter form so picking a checkbox or changing a select
// reloads the list immediately, with no Apply button required.
//
// Usage:
//   <form data-controller="auto-submit">
//     <select data-action="change->auto-submit#submit"> ... </select>
//   </form>
//
// `requestSubmit()` (rather than `.submit()`) ensures Turbo intercepts
// the navigation, preserving turbo_action: "advance" so URLs update.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
// @license-end
