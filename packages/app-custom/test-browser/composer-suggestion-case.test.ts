import { describe, expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { useFilteredList } from "@opencode/ui-custom/hooks"
import { snippetSuggestions } from "@/settings/snippets/model"

type Item = { id: string; label: string; trigger?: string; title?: string; search?: string }

// The composer filters `@`, `$`, `#` and `/` suggestions with these keys (editor/interaction.ts).
const keys = {
  context: ["label", "search"],
  skill: ["label"],
  snippet: ["search", "label"],
  command: ["trigger", "title"],
}

async function filter(items: Item[], filterKeys: string[], query: string) {
  const { list, dispose } = createRoot((dispose) => ({
    list: useFilteredList<Item>({ items, key: (item) => item.id, filterKeys }),
    dispose,
  }))
  list.onInput(query)
  await new Promise((resolve) => setTimeout(resolve, 0))
  const ids = list.flat().map((item) => item.id)
  dispose()
  return ids
}

describe("composer suggestion filters ignore case", () => {
  test("for every trigger, keeping the prefix match first", async () => {
    const context = [
      { id: "agent:general", label: "@general" },
      { id: "app:safari", label: "Safari" },
      { id: "session:s", label: "Sessão Revisão", search: "Sessão Revisão ses_1 /repo" },
    ]
    for (const query of ["saf", "SAF", "Saf"])
      expect(await filter(context, keys.context, query)).toEqual(["app:safari"])
    for (const query of ["GENERAL", "General"])
      expect(await filter(context, keys.context, query)).toEqual(["agent:general"])
    expect(await filter(context, keys.context, "SESSÃO")).toEqual(["session:s"])

    const skills = [
      { id: "skill:recommit", label: "$recommit" },
      { id: "skill:commit", label: "$commit" },
    ]
    for (const query of ["commit", "Commit", "COMMIT"])
      expect(await filter(skills, keys.skill, query)).toEqual(["skill:commit", "skill:recommit"])

    const snippets = snippetSuggestions([
      { id: "push", name: "commit-push-pr", description: "Commit e PR", aliases: ["cpp"], content: "x" },
    ]) satisfies Item[]
    for (const query of ["COMMIT", "Commit", "CPP"])
      expect(await filter(snippets, keys.snippet, query)).toEqual(["snippet:push"])

    const commands = [
      { id: "review", label: "/review", trigger: "review", title: "review" },
      { id: "commit", label: "/commit", trigger: "commit", title: "commit" },
    ]
    for (const query of ["commit", "COMMIT", "Commit"])
      expect(await filter(commands, keys.command, query)).toEqual(["commit"])
  })
})
