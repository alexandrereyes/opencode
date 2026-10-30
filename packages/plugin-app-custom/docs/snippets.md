# Snippets (`custom.snippets`)

A snippet is a saved text that the composer inserts with `#`: the iPhone and Mac apps show `#name` as a token, and on
send the token becomes the snippet's content, as plain text. `@`, `&`, `$` or `#` inside the content stay text; there
are no variables. The apps manage the catalog in **Ajustes ▸ Snippets** (rev. 2026-10-30).

## Storage and scope

- One catalog per server, in the plugin storage key `snippets:catalog`. Every Location's plugin instance reads and
  writes the same catalog atomically, so every app connected to the server sees the same snippets.
- `project` absent: **global**, offered in every conversation. `project` set: offered only in sessions of that
  Core project (`Project.ID`). A project snippet may share a global one's name; in that project, `#` offers the
  project one instead.
- A snippet whose project no longer exists is kept; the apps list it under "Projeto removido".

## Contract

```ts
Info {
  id: string            // non-empty; chosen by the client (the apps use a lowercase UUID)
  name: string          // the `#name` trigger
  description: string   // may be empty
  aliases: string[]     // other words that find it after `#`
  content: string       // must have a non-whitespace character
  project?: Project.ID  // absent: global
}
```

| Method   | Input    | Output                                    | Errors                                     |
| -------- | -------- | ----------------------------------------- | ------------------------------------------ |
| `list`   | `{}`     | `{ items: Info[] }` (storage order)       | —                                          |
| `save`   | `Info`   | `Info`                                    | `conflict`, `invalid`, `rpc.invalid_input` |
| `remove` | `{ id }` | `{}` (idempotent: an unknown ID succeeds) | —                                          |

`save` creates or replaces by `id` (last write wins; there is no revision). `save` and `remove` emit the event
`rpc.custom.snippets.updated` with `{}` on the Location of the call; clients reload the whole list when they see it.
The apps' composers reload their `#` catalog on it, so an open conversation offers a new snippet at once.

Errors are `RpcError` bodies (HTTP 400) with an English `message` and structured `data`; the apps render their own
Portuguese text from `data`:

```ts
conflict: { name, field?: "name" | "alias", value?, existing? }  // `field`, `value`, `existing` since rev. 2026-10-30
invalid:  { field: "name" | "aliases", reason: "format" | "duplicate", value }  // rev. 2026-10-30
```

## Validation (rev. 2026-10-30)

`save` checks, inside the same atomic update, in this order (`src/snippets/rules.ts`; the apps run the same rules in
`OpenCodeKit/Snippets.swift` while typing):

1. **Format** of the name, then of each alias: letters (accented ones too, composed or decomposed), digits, `-` and
   `_` (`/^[\p{L}\p{M}\p{N}_-]+$/u`). No whitespace, `#`, `@`, `$` or other punctuation: the composer's `#` query
   stops at those, so such a handle could not be typed. → `invalid { field, reason: "format", value }`.
2. **Repetition** inside the snippet: an alias equal to the name or to an earlier alias, ignoring case. →
   `invalid { field: "aliases", reason: "duplicate", value }`.
3. **Uniqueness in the scope**: the name and every alias against the names and aliases of the other snippets with the
   same `project` (or the other global ones), ignoring case (Unicode NFC, lowercase). →
   `conflict { name, field, value, existing }`.

The schema still accepts the older, looser names (`^[^\s#]+$`) when decoding stored data, so an existing catalog
keeps loading; such a snippet must follow the rules above the next time it is saved. Older clients only read `list`.

## Tests

`test/snippets.test.ts` (rules and wire schemas) and `test/server-snippets.test.ts` (one catalog across Locations on
a real server, concurrent writes, conflict and invalid errors on the wire, the `updated` event on save and remove,
persistence across restarts).
