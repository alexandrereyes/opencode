import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { list } from "../src/navigation"
import { Navigation } from "../src/navigation/rpc"
import type { PendingSnapshot } from "../src/request-times"

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
        background: () => Effect.succeed([]),
        active: () => Effect.succeed({}),
      },
      {},
    ),
  )

  expect(result.data.map((row) => row.unreadAt)).toEqual([20, 30, 20, undefined, undefined])
  expect(result.data[0]).toMatchObject({ permissionAt: 7, questionAt: 9, permissionCount: 1, questionCount: 2 })
  expect(typeof result.data[0].session.time.created).toBe("number")
  expect(Navigation.Definition.id).toBe("custom.navigation")

  pending = []
  const cleared = await Effect.runPromise(
    list(
      {
        scan: () => Effect.succeed({ data: [rows[0]] }),
        pending: () => Effect.succeed(pending),
        background: () => Effect.succeed([]),
        active: () => Effect.succeed({}),
      },
      {},
    ),
  )
  expect(cleared.data[0].permissionAt).toBeUndefined()
  expect(cleared.data[0].questionAt).toBeUndefined()
  expect(cleared.data[0].permissionCount).toBeUndefined()
  expect(cleared.data[0].questionCount).toBeUndefined()
  expect(cleared.data[0].backgroundCount).toBeUndefined()
})

test("counts background work other than subagents and names the newest", async () => {
  const rows = [
    { session: session("ses_shells", { idle: 30, outcome: "succeeded" }) },
    { session: session("ses_agent", {}) },
  ]
  const result = await Effect.runPromise(
    list(
      {
        scan: () => Effect.succeed({ data: rows }),
        pending: () => Effect.succeed([]),
        background: () =>
          Effect.succeed([
            { id: "sh_old", type: "shell", sessionID: rows[0].session.id, title: "bun run dev", started: 10 },
            { id: "sh_new", type: "shell", sessionID: rows[0].session.id, title: "bun test", started: 20 },
            { id: "ses_child", type: "subagent", sessionID: rows[1].session.id, title: "Explorar", started: 30 },
          ]),
        active: () => Effect.succeed({}),
      },
      {},
    ),
  )

  expect(result.data[0]).toMatchObject({ backgroundCount: 2, backgroundTitle: "bun test" })
  expect(result.data[1].backgroundCount).toBeUndefined()
  expect(result.data[1].backgroundTitle).toBeUndefined()
  expect(Schema.decodeUnknownSync(Navigation.Page)(result).data[0].backgroundCount).toBe(2)
})

test("shells of a subagent whose turn ended are detached; an executing subagent's still count (rev. 2026-11-06)", async () => {
  const rows = [
    { session: session("ses_root", { idle: 30, outcome: "succeeded" }) },
    { session: session("ses_android", { parentID: "ses_root", idle: 20, outcome: "succeeded" }) },
    { session: session("ses_ios", { parentID: "ses_root" }) },
    { session: session("ses_quiet", { parentID: "ses_root", idle: 20, outcome: "succeeded" }) },
  ]
  let reads = 0
  const read = (active: Record<string, { type: "running" }>) =>
    Effect.runPromise(
      list(
        {
          scan: () => Effect.succeed({ data: rows }),
          pending: () => Effect.succeed([]),
          background: () =>
            Effect.succeed([
              { id: "sh_root", type: "shell", sessionID: rows[0].session.id, title: "bun run dev", started: 5 },
              { id: "sh_old", type: "shell", sessionID: rows[1].session.id, title: "adb logcat", started: 10 },
              {
                id: "sh_emu",
                type: "shell",
                sessionID: rows[1].session.id,
                title: "android-emulator -avd Pixel",
                started: 15,
              },
              { id: "sh_sim", type: "shell", sessionID: rows[2].session.id, title: "xcodebuild test", started: 20 },
            ]),
          active: () => {
            reads++
            return Effect.succeed(active)
          },
        },
        {},
      ),
    )
  const result = await read({ ses_ios: { type: "running" } })
  // The top-level session's own shell wakes it: work. The Android subagent already answered: listed apart.
  expect(result.data[0]).toMatchObject({ backgroundCount: 1, backgroundTitle: "bun run dev" })
  expect(result.data[0]).not.toHaveProperty("detachedCount")
  expect(result.data[1]).toMatchObject({ detachedCount: 2, detachedTitle: "android-emulator -avd Pixel" })
  expect(result.data[1]).not.toHaveProperty("backgroundCount")
  expect(result.data[1]).not.toHaveProperty("backgroundTitle")
  // The iOS subagent still executes: its shell is work its parent waits on.
  expect(result.data[2]).toMatchObject({ backgroundCount: 1, backgroundTitle: "xcodebuild test" })
  expect(result.data[2]).not.toHaveProperty("detachedCount")
  expect(result.data[3]).not.toHaveProperty("backgroundCount")
  expect(result.data[3]).not.toHaveProperty("detachedCount")
  expect(Schema.decodeUnknownSync(Navigation.Page)(result).data[1]).toMatchObject({ detachedCount: 2 })
  // Continued, the Android subagent's shells count again.
  expect((await read({ ses_android: { type: "running" } })).data[1]).toMatchObject({ backgroundCount: 2 })
  expect(reads).toBe(2)
})

test("reads the running set only when some background work exists", async () => {
  let reads = 0
  await Effect.runPromise(
    list(
      {
        scan: () => Effect.succeed({ data: [{ session: session("ses_root", {}) }] }),
        pending: () => Effect.succeed([]),
        background: () => Effect.succeed([]),
        active: () => {
          reads++
          return Effect.succeed({})
        },
      },
      {},
    ),
  )
  expect(reads).toBe(0)
})

test("a session's Progresso rides its row while it shows; old clients ignore the field", async () => {
  const rows = [{ session: session("ses_plan", {}) }, { session: session("ses_none", {}) }]
  const progress = {
    done: 1,
    finished: 2,
    total: 3,
    current: "Rodar os testes",
    todos: [
      { content: "Ler", status: "completed" as const },
      { content: "Migrar", status: "cancelled" as const },
      { content: "Rodar os testes", status: "in_progress" as const },
    ],
  }
  const result = await Effect.runPromise(
    list(
      {
        scan: () => Effect.succeed({ data: rows }),
        pending: () => Effect.succeed([]),
        background: () => Effect.succeed([]),
        active: () => Effect.succeed({}),
        progress: (sessionID) => (sessionID === "ses_plan" ? progress : undefined),
      },
      {},
    ),
  )
  expect(result.data[0].progress).toEqual(progress)
  expect(result.data[1]).not.toHaveProperty("progress")
  expect(Schema.decodeUnknownSync(Navigation.Page)(result).data[0].progress).toEqual(progress)
})
