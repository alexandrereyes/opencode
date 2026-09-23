import { canonicalPickerPath, normalizePickerPath, pickerParent, pickerRoot, trimPickerPath } from "./domain"

// The query doubles as location and filter: text up to the last separator is the browsed
// directory and the trailing segment filters its children, e.g. `~/Dev/op`.
export function explorerQuery(query: string, home: string) {
  const value = normalizePickerPath(query)
  const slash = value.lastIndexOf("/")
  const directory = slash < 0 ? "" : value.slice(0, slash + 1)
  return {
    directory,
    filter: value.slice(slash + 1),
    browsed: explorerAbsolute(directory, home),
    target: explorerAbsolute(value, home),
  }
}

export function explorerAbsolute(display: string, home: string) {
  const value = normalizePickerPath(display.trim())
  if ((value === "~" || value.startsWith("~/")) && !home) return ""
  const expanded = value === "~" || value.startsWith("~/") ? trimPickerPath(home) + value.slice(1) : value
  if (!expanded || !pickerRoot(expanded)) return ""
  return canonicalPickerPath(expanded)
}

// Unlike picker display paths, explorer paths keep forward slashes because the query is split on them.
export function explorerDisplay(absolute: string, home: string) {
  const value = trimPickerPath(absolute)
  const root = home ? trimPickerPath(home) : ""
  const display = !root ? value : value === root ? "~" : value.startsWith(root + "/") ? "~" + value.slice(root.length) : value
  return display.endsWith("/") ? display : display + "/"
}

export function explorerParent(query: string, home: string) {
  const current = explorerQuery(query, home)
  if (!current.browsed || current.filter) return
  const parent = pickerParent(current.browsed)
  if (parent === trimPickerPath(current.browsed)) return
  return explorerDisplay(parent, home)
}

export function explorerRows(input: {
  entries: ReadonlyArray<{ name: string; absolute: string }>
  filter: string
  hidden: boolean
  added: ReadonlySet<string>
}) {
  const filter = input.filter.toLowerCase()
  const hidden = input.hidden || input.filter.startsWith(".")
  return input.entries
    .filter((entry) => entry.name.toLowerCase().startsWith(filter) && (hidden || !entry.name.startsWith(".")))
    .toSorted((left, right) => left.name.localeCompare(right.name))
    .map((entry) => ({
      name: entry.name,
      absolute: trimPickerPath(entry.absolute),
      added: input.added.has(trimPickerPath(entry.absolute)),
    }))
}

export function explorerSubmission(input: {
  query: string
  home: string
  selected: readonly string[]
  added: ReadonlySet<string>
  readable: boolean
  rows: ReadonlyArray<{ name: string; absolute: string }>
}) {
  if (input.selected.length > 0) return { type: "selected" as const, paths: [...input.selected] }
  const current = explorerQuery(input.query, input.home)
  if (!current.target || !input.readable) return
  if (input.added.has(current.target)) return { type: "added" as const, path: current.target }
  if (!current.filter || input.rows.some((row) => row.name === current.filter))
    return { type: "existing" as const, path: current.target }
  return { type: "create" as const, path: current.target }
}
