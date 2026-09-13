import type { Snippets } from "@opencode/plugin-app-custom/snippets/rpc"
import type { ComposerSuggestion } from "@/composer/types"

export type Snippet = Snippets.Info

export function isSnippetConflict(error: unknown) {
  return typeof error === "object" && error !== null && "type" in error && error.type === "conflict"
}

export function snippetSuggestions(snippets: readonly Snippet[], project?: string): ComposerSuggestion[] {
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
