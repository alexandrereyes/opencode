import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { snapshot } from "../src/session-family"
import { Family } from "../src/session-family/rpc"

function session(id: string, parentID?: string) {
  return Schema.decodeUnknownSync(Session.Info)({
    id,
    ...(parentID ? { parentID } : {}),
    projectID: Project.ID.global,
    location: { directory: "/repo" },
    cost: 0,
    time: { created: 1, updated: 1 },
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  })
}

test("finds pending grandchildren absent from pages, shares ancestry reads and prioritizes root prompts", async () => {
  const root = session("ses_root")
  const child = session("ses_child", root.id)
  const grandchild = session("ses_grandchild", child.id)
  const unrelated = session("ses_unrelated")
  const reads: string[] = []
  const form = (id: string, owner: string, kind: string): Form.Info => ({
    id: Form.ID.create(id),
    sessionID: owner,
    title: "Question",
    created: 1,
    fields: [{ key: "answer", type: "string" }],
    metadata: { kind },
  })
  const result = await Effect.runPromise(
    snapshot(
      {
        family: () => Effect.succeed({ count: 154, cost: 17, data: [], active: [child] }),
        get: ({ sessionID }) => {
          reads.push(sessionID)
          const value = [root, child, grandchild, unrelated].find((session) => session.id === sessionID)
          return value ? Effect.succeed(value) : Effect.fail(new Error("missing"))
        },
        pending: () =>
          Effect.succeed([
            {
              location: { directory: AbsolutePath.make("/repo") },
              forms: [
                form("frm_nested", grandchild.id, "question"),
                form("frm_child", child.id, "websearch.provider"),
                form("frm_other", unrelated.id, "question"),
                form("frm_global", "global", "question"),
                form("frm_root", root.id, "question"),
                form("frm_ignored", root.id, "other"),
              ],
              permissions: [
                { id: Permission.ID.create("per_nested"), sessionID: grandchild.id, action: "read", resources: [] },
              ],
            },
          ]),
      },
      root.id,
    ),
  )
  expect(result.forms.map((form) => form.id)).toEqual(["frm_root", "frm_child", "frm_nested"])
  expect(result.permissions.map((permission) => permission.id)).toEqual(["per_nested"])
  expect(result.active[0].time.created).toBe(1)
  expect(reads).toEqual([grandchild.id, child.id, unrelated.id])
  expect(Family.Definition.id).toBe("custom.session-family")
})

test("propagates missing root instead of returning an empty successful snapshot", async () => {
  const missing = new Error("Session.NotFoundError")
  const result = await Effect.runPromise(
    snapshot(
      {
        family: () => Effect.fail(missing),
        get: () => Effect.fail(missing),
        pending: () => Effect.succeed([]),
      },
      Session.ID.make("ses_missing"),
    ).pipe(Effect.flip),
  )
  expect(result).toBe(missing)
})
