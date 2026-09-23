import { expect, test } from "bun:test"
import { Session } from "@opencode/schema/session"
import { btwQuestionText } from "./question"

test("expands snippet content and retains file references as text", () => {
  expect(
    btwQuestionText([
      { type: "snippet", id: "why", name: "why", content: "#why", expansion: "Explain this", start: 0, end: 4 },
      { type: "text", content: " ", start: 4, end: 5 },
      { type: "file", path: "src/main.ts", content: "@src/main.ts", start: 5, end: 17 },
    ]),
  ).toBe("Explain this @src/main.ts")
})

test("includes app and session identities through the shared prompt formatters", () => {
  const text = btwQuestionText([
    {
      type: "app",
      content: "@Editor",
      start: 0,
      end: 7,
      app: { name: "Editor", server: "computer", bundleID: "editor", running: true },
    },
    {
      type: "session",
      content: "@Other",
      start: 7,
      end: 13,
      session: { id: Session.ID.make("ses_other"), server: "local", title: "Other", directory: "/project" },
    },
  ])
  expect(text).toStartWith("@Editor@Other")
  expect(text).toContain("Computer use app selected by the user")
  expect(text).toContain("Referenced OpenCode session:")
  expect(text).toContain('"sessionID":"ses_other"')
})

test("drops binary attachments without reading/uploading them; keeps typed citations", () => {
  expect(
    btwQuestionText([
      { type: "text", content: "About [photo.png]", start: 0, end: 17 },
      {
        type: "image",
        id: "photo",
        filename: "photo.png",
        mime: "image/png",
        blob: { id: "blob", url: "blob:unreadable" },
      },
    ]),
  ).toBe("About [photo.png]")
})
