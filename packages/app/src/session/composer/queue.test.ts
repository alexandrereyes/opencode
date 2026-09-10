import { describe, expect, test } from "bun:test"
import type { SessionInboxInfo } from "@opencode/client/promise"
import { Session } from "@opencode/schema/session"
import { editedPromptInput, queuedPromptRows } from "./queue"
import type { SessionPart } from "@/composer/state"
import { formatSessionContext } from "@/composer/session-reference"

const queued = [
  {
    id: "msg_original",
    sessionID: "ses_1",
    timeCreated: 1,
    type: "user",
    delivery: "queue",
    payload: { text: "original" },
  },
  {
    id: "msg_replacement",
    sessionID: "ses_1",
    timeCreated: 2,
    type: "user",
    delivery: "queue",
    payload: { text: "edited" },
  },
] satisfies SessionInboxInfo[]

describe("queuedPromptRows", () => {
  test("keeps the edited prompt to one row while its replacement is admitted", () => {
    expect(queuedPromptRows(queued, { original: "msg_original", replacement: "msg_replacement" })).toEqual([
      { id: "msg_replacement", text: "edited", attachments: 0 },
    ])
  })

  test("keeps the original visible until its replacement appears", () => {
    expect(queuedPromptRows([queued[0]], { original: "msg_original", replacement: "msg_replacement" })).toEqual([
      { id: "msg_original", text: "original", attachments: 0 },
    ])
  })

  test("retains unrelated queue entries", () => {
    expect(queuedPromptRows(queued)).toEqual([
      { id: "msg_original", text: "original", attachments: 0 },
      { id: "msg_replacement", text: "edited", attachments: 0 },
    ])
  })

  test("keeps other prompts visible while a mutation replaces the edited prompt", () => {
    const other = { ...queued[0], id: "msg_other", payload: { text: "other" } }

    expect(
      queuedPromptRows([queued[0], other, queued[1]], { original: "msg_original", replacement: "msg_replacement" }),
    ).toEqual([
      { id: "msg_other", text: "other", attachments: 0 },
      { id: "msg_replacement", text: "edited", attachments: 0 },
    ])
  })
})

test("queue edits replace session metadata and model context", async () => {
  const original: SessionPart = {
    type: "session",
    content: "@Same",
    start: 0,
    end: 5,
    session: { id: Session.ID.make("ses_old"), server: "sidecar", title: "Same", directory: "/old" },
  }
  const replacement: SessionPart = {
    ...original,
    session: { id: Session.ID.make("ses_new"), server: "sidecar", title: "Same", directory: "/new" },
  }
  const item = {
    id: "msg_original",
    sessionID: "ses_current",
    timeCreated: 1,
    type: "user",
    delivery: "queue",
    payload: {
      text: `@Same\n${formatSessionContext(original)}`,
      metadata: { displayText: "@Same", sessions: [original] },
    },
  } as Extract<SessionInboxInfo, { type: "user" }>

  const result = await editedPromptInput("ses_current", "/current", item, [replacement], "@Same", [])

  expect(result.metadata.sessions).toEqual([replacement])
  expect(result.text).toContain('"sessionID":"ses_new"')
  expect(result.text).not.toContain('"sessionID":"ses_old"')
})
