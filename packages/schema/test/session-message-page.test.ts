import { expect, test } from "bun:test"
import { Effect } from "effect"
import { MessagePage } from "../src/session-message-page.js"
import { SessionMessage } from "../src/session-message.js"

test("preserves the message cursor wire format", async () => {
  const input = {
    id: SessionMessage.ID.make("msg_example"),
    order: "desc" as const,
    direction: "next" as const,
  }
  const cursor = MessagePage.Cursor.make(input)

  expect(String(cursor)).toBe("eyJpZCI6Im1zZ19leGFtcGxlIiwib3JkZXIiOiJkZXNjIiwiZGlyZWN0aW9uIjoibmV4dCJ9")
  expect(await Effect.runPromise(MessagePage.Cursor.parse(cursor))).toEqual(input)
})

test("fails malformed message cursors", async () => {
  expect(await Effect.runPromiseExit(MessagePage.Cursor.parse("not-a-cursor"))).toMatchObject({ _tag: "Failure" })
})
