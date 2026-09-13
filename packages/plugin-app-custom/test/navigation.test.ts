import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { list } from "../src/navigation"
import { Navigation } from "../src/navigation/rpc"
import type { PendingSnapshot } from "@opencode/plugin/effect/request"

const decodeSession = Schema.decodeUnknownSync(Session.Info)

function session(
  id: string,
  input: { parentID?: string; idle?: number; viewed?: number; outcome?: "succeeded" | "failed" | "interrupted" },
) {
  return decodeSession({
    id,
    ...(input.parentID === undefined ? {} : { parentID: input.parentID }),
    projectID: Project.ID.global,
    location: { directory: AbsolutePath.make("/repo") },
    title: id,
    ...(input.outcome === undefined ? {} : { outcome: input.outcome }),
    time: {
      created: 1,
      updated: 2,
      ...(input.idle === undefined ? {} : { idle: input.idle }),
      ...(input.viewed === undefined ? {} : { viewed: input.viewed }),
    },
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  })
}

test("preserves unread precedence, root policy, pending classification, and wire dates", async () => {
  const rows = [
    { session: session("ses_durable", { idle: 30, outcome: "succeeded" }), completionAt: 20 },
    { session: session("ses_fallback", { idle: 30, outcome: "failed" }) },
    { session: session("ses_interrupted", { idle: 40, outcome: "interrupted" }), completionAt: 20 },
    { session: session("ses_viewed", { idle: 40, viewed: 25, outcome: "interrupted" }), completionAt: 20 },
    { session: session("ses_child", { parentID: "ses_durable", idle: 50, outcome: "succeeded" }), completionAt: 50 },
  ]
  let pending: ReadonlyArray<PendingSnapshot> = [
    {
      location: { directory: AbsolutePath.make("/repo") },
      permissions: [
        {
          id: Permission.ID.create("per_1"),
          sessionID: rows[0].session.id,
          action: "read",
          resources: [],
          created: 7,
        },
      ],
      forms: [
        {
          id: Form.ID.create("frm_1"),
          sessionID: rows[0].session.id,
          title: "Question",
          fields: [{ key: "answer", type: "string" as const }],
          created: 8,
          metadata: { kind: "question" },
        },
        {
          id: Form.ID.create("frm_2"),
          sessionID: rows[0].session.id,
          title: "Provider",
          fields: [{ key: "answer", type: "string" as const }],
          created: 9,
          metadata: { kind: "websearch.provider" },
        },
        {
          id: Form.ID.create("frm_3"),
          sessionID: rows[0].session.id,
          title: "Ignored",
          fields: [{ key: "answer", type: "string" as const }],
          created: 100,
        },
      ],
    },
  ]
  const result = await Effect.runPromise(
    list(
      {
        scan: (input) => Effect.succeed({ data: rows, next: input?.after }),
        pending: () => Effect.succeed(pending),
      },
      {},
    ),
  )

  expect(result.data.map((row) => row.unreadAt)).toEqual([20, 30, 20, undefined, undefined])
  expect(result.data[0]).toMatchObject({ permissionAt: 7, questionAt: 9 })
  expect(typeof result.data[0].session.time.created).toBe("number")
  expect(Navigation.Definition.id).toBe("custom.navigation")

  pending = []
  const cleared = await Effect.runPromise(
    list({ scan: () => Effect.succeed({ data: [rows[0]] }), pending: () => Effect.succeed(pending) }, {}),
  )
  expect(cleared.data[0].permissionAt).toBeUndefined()
  expect(cleared.data[0].questionAt).toBeUndefined()
})
