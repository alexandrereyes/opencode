import type { Snippets } from "./rpc.js"

/**
 * What a name or alias may be (rev. 2026-10-30): letters (accents too), digits, `-` and `_`. The composer's `#` query
 * stops at whitespace, `#`, `@` and `$`, so a handle with any of them could not be typed. `docs/snippets.md`.
 */
export const handle = /^[\p{L}\p{M}\p{N}_-]+$/u

export type Problem =
  | {
      readonly type: "invalid"
      readonly data: {
        readonly field: "name" | "aliases"
        readonly reason: "format" | "duplicate"
        readonly value: string
      }
    }
  | {
      readonly type: "conflict"
      readonly data: {
        readonly name: string
        readonly field: "name" | "alias"
        readonly value: string
        readonly existing: string
      }
    }

/**
 * The first rule `snippet` breaks against the catalog, or nothing. Every handle (name and aliases) is unique in its
 * scope, ignoring case: a project's snippets and the global ones are separate scopes, and a project snippet may take
 * a global one's name (it replaces it in that project's `#`).
 */
export function problem(items: readonly Snippets.Info[], snippet: Snippets.Info): Problem | undefined {
  if (!handle.test(snippet.name)) return invalid("name", "format", snippet.name)
  const malformed = snippet.aliases.find((alias) => !handle.test(alias))
  if (malformed !== undefined) return invalid("aliases", "format", malformed)
  const own = [snippet.name, ...snippet.aliases].map(key)
  const repeated = snippet.aliases.find((alias, index) => own.indexOf(key(alias)) !== index + 1)
  if (repeated !== undefined) return invalid("aliases", "duplicate", repeated)
  const others = items.filter((item) => item.id !== snippet.id && item.project === snippet.project)
  const handles = [
    { field: "name" as const, value: snippet.name },
    ...snippet.aliases.map((value) => ({ field: "alias" as const, value })),
  ]
  return handles.flatMap((entry): Problem[] => {
    const existing = others.find((item) =>
      [item.name, ...item.aliases].some((other) => key(other) === key(entry.value)),
    )
    if (!existing) return []
    return [
      {
        type: "conflict",
        data: { name: snippet.name, field: entry.field, value: entry.value, existing: existing.name },
      },
    ]
  })[0]
}

export const key = (value: string) => value.normalize("NFC").toLowerCase()

const invalid = (field: "name" | "aliases", reason: "format" | "duplicate", value: string): Problem => ({
  type: "invalid",
  data: { field, reason, value },
})
