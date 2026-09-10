import { describe, expect, test } from "bun:test"
import { Schema } from "effect"
import { createStore } from "solid-js/store"
import { createComposerEditorActions } from "@/composer/editor/actions"
import { ComposerStore } from "@/composer/schema"
import { buildPromptRequest } from "@/composer/request"
import { createComposerInteractionState, transitionComposer } from "@/composer/suggestions/machine"
import { snippetAliases, snippetSuggestions, type Snippet } from "./model"

const global: Snippet = {
  id: "global",
  name: "review",
  description: "Review code",
  aliases: ["audit"],
  content: "Review carefully.\nKeep it simple.",
}

describe("snippets", () => {
  test("keeps global snippets, scopes projects and overrides names case-insensitively", () => {
    const project = { ...global, id: "project", project: "local\u0000repo", name: "Review", content: "Local review" }
    expect(snippetSuggestions([global, project], project.project).map((item) => item.mention)).toMatchObject([
      { id: "project", content: "#Review", expansion: "Local review" },
    ])
    expect(snippetSuggestions([global, project], "remote\u0000repo").map((item) => item.id)).toEqual(["snippet:global"])
    expect(snippetSuggestions([global])[0]?.search).toContain("audit")
    expect(snippetAliases("audit, test, audit,\n review ")).toEqual(["audit", "test", "review"])
  })

  test("triggers at the cursor and leaves anchors, headings and shell text alone", () => {
    const state = createComposerInteractionState()
    const input: ComposerStore = { prompt: [], cursor: 9, context: { items: [] } }
    expect(
      transitionComposer(state, { type: "input.changed", value: "Use #revi later", persist: false }, input).state
        .popover,
    ).toEqual({ type: "snippet", query: "revi" })
    for (const text of ["url#review", "##", "# heading", "issue#42"]) {
      expect(
        transitionComposer(state, { type: "input.changed", value: text }, { ...input, cursor: text.length }).state
          .popover.type,
      ).toBe("closed")
    }
    expect(
      transitionComposer({ ...state, mode: "shell" }, { type: "input.changed", value: "#review" }, input).state.popover
        .type,
    ).toBe("closed")
  })

  test("selected snippets round-trip as tokens and expand with correct following mention offsets", () => {
    const actions = createComposerEditorActions(
      createStore<ComposerStore>({
        prompt: [
          { type: "text", content: "Use #au then ", start: 0, end: 13 },
          { type: "file", path: "file.ts", content: "@file.ts", start: 13, end: 21 },
        ],
        cursor: 7,
        context: { items: [] },
      }),
    )
    const mention = snippetSuggestions([global])[0]?.mention
    if (!mention) throw new Error("Missing snippet suggestion")
    actions.addMention(mention)
    expect(actions.state.cursor).toBe(12)
    expect(actions.state.prompt.map((part) => ("content" in part ? part.content : "")).join("")).toBe(
      "Use #review  then @file.ts",
    )
    const restored = Schema.decodeUnknownSync(ComposerStore)(Schema.encodeSync(ComposerStore)(actions.state))
    const request = buildPromptRequest({
      prompt: restored.prompt,
      context: [],
      images: [],
      text: "Use #review  then @file.ts",
      sessionDirectory: "/repo",
    })
    expect(request.text).toBe(`Use ${global.content}  then @file.ts`)
    expect(request.displayText).toBe(request.text)
    expect(request.files[0]?.mention).toEqual({
      start: request.text.indexOf("@file.ts"),
      end: request.text.length,
      text: "@file.ts",
    })
    expect(restored.prompt[1]).toMatchObject({ type: "snippet", content: "#review", expansion: global.content })
  })
})
