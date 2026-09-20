import { expect, test } from "bun:test"
import { readPromptPresentation } from "./comment-note"

test("reads path attachment presentation metadata alongside custom quotes", () => {
  expect(
    readPromptPresentation({
      displayText: "inspect this",
      comments: [],
      attachments: [{ name: "archive.zip", mime: "application/zip", path: "/tmp/archive.zip" }],
      quotes: [],
    }),
  ).toEqual({
    displayText: "inspect this",
    comments: [],
    attachments: [{ name: "archive.zip", mime: "application/zip", path: "/tmp/archive.zip" }],
    quotes: [],
  })
})
