/**
 * What every Chrome viewer shares, whatever reaches the browser (CDP for `playwright-cli` browsers, browse's tools for
 * an agent's tabs in Alexandre's Chrome): the `meta` it publishes, the focused field and typed addresses.
 */

export type Field =
  | "text"
  | "multiline"
  | "password"
  | "email"
  | "username"
  | "url"
  | "tel"
  | "number"
  | "search"
  | "one-time-code"

/** What the viewer needs to show the right keyboard. Never includes the field's value. */
export interface Focus {
  readonly editable: boolean
  readonly field?: Field
}

export interface Tab {
  readonly id: string
  readonly title: string
  readonly url: string
}

/** `meta` payload of the stream; the viewer replaces its state with each one. */
export interface ChromeState {
  readonly url: string
  readonly title: string
  readonly canGoBack: boolean
  readonly canGoForward: boolean
  readonly targetID: string
  readonly tabs: readonly Tab[]
  readonly focus: Focus
  /** Counts taps that landed on an editable field, so the viewer reopens its keyboard on the same field. */
  readonly editTaps: number
  /** CSS pixels of the mirrored viewport. */
  readonly viewport?: { readonly width: number; readonly height: number }
}

/** Normalizes what the viewer typed into the address bar. */
export function normalizeURL(input: string) {
  const value = input.trim()
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) && !/^[^/:]+:\d+/.test(value)) return value
  const local = /^(localhost|127\.|\[::1\]|0\.0\.0\.0|10\.|192\.168\.|[^/:]+\.local\b)/i.test(value)
  return `${local ? "http" : "https"}://${value}`
}

/** Runs in the page: classifies the focused editable element (through shadow roots and same-origin frames). */
export const focusScript = `(() => {
  const classify = (element) => {
    if (element.isContentEditable) return { editable: true, field: "multiline" }
    if (element.tagName === "TEXTAREA") return element.disabled || element.readOnly ? { editable: false } : { editable: true, field: "multiline" }
    if (element.tagName !== "INPUT" || element.disabled || element.readOnly) return { editable: false }
    const type = (element.type || "text").toLowerCase()
    if (["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"].includes(type)) return { editable: false }
    const auto = (element.getAttribute("autocomplete") || "").toLowerCase()
    if (type === "password" || /(current|new)-password/.test(auto)) return { editable: true, field: "password" }
    if (/one-time-code/.test(auto)) return { editable: true, field: "one-time-code" }
    if (/username/.test(auto)) return { editable: true, field: "username" }
    if (type === "email" || /email/.test(auto)) return { editable: true, field: "email" }
    if (["url", "tel", "number", "search"].includes(type)) return { editable: true, field: type }
    return { editable: true, field: "text" }
  }
  let element = document.activeElement
  for (let depth = 0; element && depth < 16; depth++) {
    if (element.shadowRoot && element.shadowRoot.activeElement) { element = element.shadowRoot.activeElement; continue }
    if (element.tagName === "IFRAME" || element.tagName === "FRAME") {
      let inner = null
      try { inner = element.contentDocument && element.contentDocument.activeElement } catch {}
      if (!inner) return { editable: true, field: "text" }
      element = inner
      continue
    }
    break
  }
  return element ? classify(element) : { editable: false }
})()`

const fields = new Set<string>([
  "text",
  "multiline",
  "password",
  "email",
  "username",
  "url",
  "tel",
  "number",
  "search",
  "one-time-code",
])

export function decodeFocus(value: unknown): Focus {
  if (typeof value !== "object" || value === null || !("editable" in value) || value.editable !== true)
    return { editable: false }
  const field = "field" in value && typeof value.field === "string" && fields.has(value.field) ? value.field : "text"
  // `fields` holds exactly the `Field` literals.
  return { editable: true, field: field as Field }
}
