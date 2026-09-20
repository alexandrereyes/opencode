import { expect, test } from "bun:test"
import type { SessionMessageUser } from "@opencode/client/promise"
import { userPresentation } from "./user-presentation"

test("preserves attachment references with quotes and session citation presentation", () => {
  const message = {
    id: "msg_reference",
    type: "user",
    text: "inspect\nquoted model context",
    metadata: {
      displayText: "inspect",
      comments: [],
      attachments: [{ name: "archive.zip", mime: "application/zip", path: "/tmp/archive.zip" }],
      quotes: [{ id: "quote", messageID: "msg_source", partID: "part", text: "quoted model context", comment: "" }],
      sessions: [
        {
          type: "session",
          content: "@Prior",
          start: 0,
          end: 6,
          session: { id: "ses_prior", server: "local", title: "Prior", directory: "/workspace" },
        },
      ],
    },
    time: { created: 1 },
  } as SessionMessageUser

  expect(userPresentation(message)).toMatchObject({
    displayText: "inspect",
    copyText: "inspect\nquoted model context",
    references: [{ name: "archive.zip", mime: "application/zip", path: "/tmp/archive.zip" }],
    quotes: [{ id: "quote", text: "quoted model context" }],
    sessions: [{ start: 0, end: 6 }],
  })
})
