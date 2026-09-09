import { expect, test } from "bun:test"
import { createStore } from "solid-js/store"
import { Schema } from "effect"
import { ComposerStore } from "./schema"
import { createComposerEditorActions } from "./editor/actions"
import { buildPromptRequest } from "./request"
import { extractPromptFromMessage } from "./prompt"

test("app identity survives insertion, persistence, submission and message editing", () => {
  const actions = createComposerEditorActions(
    createStore<ComposerStore>({
      prompt: [{ type: "text", content: "Use @Saf then check", start: 0, end: 19 }],
      cursor: 8,
      context: { items: [] },
    }),
  )
  actions.addMention({
    type: "app",
    content: "@Safari",
    start: 0,
    end: 0,
    app: {
      server: "codex-computer-use",
      name: "Safari",
      path: "/Applications/Safari.app/",
      bundleID: "com.apple.Safari",
      running: true,
    },
  })
  const persisted = Schema.decodeUnknownSync(ComposerStore)(JSON.parse(JSON.stringify(actions.state)))
  const text = persisted.prompt.map((part) => ("content" in part ? part.content : "")).join("")
  expect(text).toBe("Use @Safari  then check")
  expect(persisted.cursor).toBe(12)
  const request = buildPromptRequest({
    prompt: persisted.prompt,
    context: [],
    images: [],
    text,
    sessionDirectory: "/remote/repo",
  })
  expect(request.text).toContain('"bundleID":"com.apple.Safari"')
  expect(request.text).toContain('"path":"/Applications/Safari.app/"')
  expect(request.text).toContain("codex-computer-use tools")
  expect(request.files).toEqual([])
  expect(request.agents).toEqual([])
  expect(
    extractPromptFromMessage({
      id: "msg_apps",
      type: "user",
      text: request.text,
      metadata: { displayText: request.displayText, comments: [], apps: request.apps },
      time: { created: 1 },
    }),
  ).toEqual(persisted.prompt)
})
