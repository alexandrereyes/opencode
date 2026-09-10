import { Schema } from "effect"
import { Persistence } from "@/runtime/persistence/schema"
import type { ComposerSuggestion } from "@/composer/types"

export const Snippet = Persistence.struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.String,
  aliases: Persistence.array(Schema.String),
  content: Schema.String,
  project: Persistence.optional(Schema.String),
})
export type Snippet = typeof Snippet.Type

export function snippetSuggestions(snippets: Snippet[], project?: string): ComposerSuggestion[] {
  const local = snippets.filter((item) => item.project === project && item.project !== undefined)
  return [
    ...local,
    ...snippets.filter(
      (item) => !item.project && !local.some((local) => local.name.toLowerCase() === item.name.toLowerCase()),
    ),
  ].map((item) => ({
    id: `snippet:${item.id}`,
    kind: "snippet",
    label: `#${item.name}`,
    description: item.description,
    search: [item.name, item.description, ...item.aliases].join(" "),
    mention: {
      type: "snippet",
      id: item.id,
      name: item.name,
      content: `#${item.name}`,
      expansion: item.content,
      start: 0,
      end: 0,
    },
  }))
}

export function snippetAliases(value: string) {
  return [
    ...new Set(
      value
        .split(/[,\n]/)
        .map((alias) => alias.trim())
        .filter(Boolean),
    ),
  ]
}
