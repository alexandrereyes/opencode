import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { archive } from "../src/archive"
import { Archive } from "../src/archive/rpc"

const root = Session.ID.make("ses_root")
const first = Session.ID.make("ses_first")
const second = Session.ID.make("ses_second")
const grandchild = Session.ID.make("ses_grandchild")
const decodeSession = Schema.decodeUnknownSync(Session.Info)
const session = (id: Session.ID, parentID?: Session.ID, archived?: number) =>
  decodeSession({
    id,
    ...(parentID ? { parentID } : {}),
    projectID: Project.ID.global,
    location: { directory: AbsolutePath.make("/repo") },
    title: id,
    time: { created: 1, updated: 1, ...(archived ? { archived } : {}) },
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  })

test("archives every page and archived intermediate descendants before their parent", async () => {
  const calls: string[] = []
  const pages = new Map([
    [`${root}:`, { data: [{ session: session(first, root) }], next: first }],
    [`${root}:${first}`, { data: [{ session: session(second, root, 1) }] }],
    [`${first}:`, { data: [] }],
    [`${second}:`, { data: [{ session: session(grandchild, second) }] }],
    [`${grandchild}:`, { data: [] }],
  ])

  await Effect.runPromise(
    archive(
      {
        interrupt: ({ sessionID }) =>
          Effect.sync(() => calls.push(`interrupt:${sessionID}`)).pipe(Effect.as({ interrupted: true })),
        wait: ({ sessionID }) => Effect.sync(() => calls.push(`wait:${sessionID}`)),
        scan: (input) =>
          Effect.sync(() => {
            const parentID = input?.parentID
            const after = input?.after
            calls.push(`scan:${parentID}:${after ?? ""}`)
            return pages.get(`${parentID}:${after ?? ""}`) ?? { data: [] }
          }),
        archive: ({ sessionID }) => Effect.sync(() => calls.push(`archive:${sessionID}`)),
      },
      { sessionID: root },
    ),
  )

  expect(calls.filter((call) => call.startsWith("archive:"))).toEqual([
    `archive:${first}`,
    `archive:${grandchild}`,
    `archive:${second}`,
    `archive:${root}`,
  ])
  expect(calls.indexOf(`wait:${root}`)).toBeLessThan(calls.indexOf(`scan:${root}:`))
  expect(calls).toContain(`scan:${root}:${first}`)
  expect(Archive.Definition.id).toBe("custom.archive")
})

test("propagates a descendant archive failure and does not archive its ancestors", async () => {
  const archived: Session.ID[] = []
  const result = await Effect.runPromise(
    Effect.result(
      archive(
        {
          interrupt: () => Effect.succeed({ interrupted: false }),
          wait: () => Effect.void,
          scan: (input) =>
            Effect.succeed({ data: input?.parentID === root ? [{ session: session(first, root) }] : [] }),
          archive: ({ sessionID }) =>
            sessionID === first
              ? Effect.fail(new Error("archive failed"))
              : Effect.sync(() => archived.push(sessionID)),
        },
        { sessionID: root },
      ),
    ),
  )

  expect(result).toMatchObject({ _tag: "Failure", failure: { message: "archive failed" } })
  expect(archived).toEqual([])
})
