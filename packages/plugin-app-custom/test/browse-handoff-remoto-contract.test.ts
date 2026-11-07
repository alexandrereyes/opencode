import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { BrowserHandoffs } from "../src/browser-handoff/rpc"
import { list } from "../src/navigation"
import { Navigation } from "../src/navigation/rpc"
import { body } from "../src/notifications/index"
import { Resources } from "../src/resources/rpc"

/**
 * The normative examples of `docs/browse-handoff-remoto.md`, which the apps decode in their own tests. Each one decodes
 * with the RPC schema it documents; the Sessões entry and the push are what this plugin actually builds.
 * `UPDATE_FIXTURES=1` rewrites those two after an intended change.
 */
const fixture = async (name: string) =>
  JSON.parse(await Bun.file(new URL(`../docs/browse-handoff-remoto/${name}.json`, import.meta.url)).text())
const write = (name: string, value: unknown) =>
  Bun.write(
    new URL(`../docs/browse-handoff-remoto/${name}.json`, import.meta.url),
    JSON.stringify(value, null, 2) + "\n",
  )

test("the handoff list, its changes, the resource and the stream messages decode with their schemas", async () => {
  const listed = Schema.decodeUnknownSync(BrowserHandoffs.ListOutput)(await fixture("handoffs-list"))
  expect(listed.data.map((item) => item.resourceID)).toEqual(["chrome:browse:github-login", undefined])
  expect(Schema.decodeUnknownSync(BrowserHandoffs.Changed)(await fixture("changed-waiting")).ended).toBeUndefined()
  const ended = (await fixture("changed-ended")) as unknown[]
  expect(ended.map((item) => Schema.decodeUnknownSync(BrowserHandoffs.Changed)(item).ended?.outcome)).toEqual([
    "completed",
    "timeout",
    "cancelled",
    "failed",
  ])
  const resource = Schema.decodeUnknownSync(Resources.Resource)(await fixture("resource"))
  expect(resource.capabilities).toEqual({ navigation: false, tabs: false })
  expect(resource.meta).toMatchObject({ kind: "chrome", browse: "github-login" })
  expect(resource.handoff?.id).toBe(listed.data[0]?.id)
  const messages = (await fixture("stream-messages")) as { type: string; reason?: string; message?: string }[]
  expect(messages.filter((item) => item.type === "end").map((item) => item.reason)).toEqual(
    Object.values(Resources.handoffEndReasons),
  )
  expect(messages.find((item) => item.type === "error")?.message).toBe("not_allowed")
})

test("Sessões carries the newest handoff's resource and the push names it", async () => {
  const session = Schema.decodeUnknownSync(Session.Info)({
    id: "ses_01JZLIVEACTIVITY0000000001",
    projectID: Project.ID.global,
    location: { directory: AbsolutePath.make("/Users/alexandremartins/Worktrees/opencode2-live-activity") },
    title: "Live Activity no iOS",
    time: { created: 1793104000000, updated: 1793104740000 },
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  })
  const listed = Schema.decodeUnknownSync(BrowserHandoffs.ListOutput)(await fixture("handoffs-list"))
  const page = await Effect.runPromise(
    list(
      {
        scan: () => Effect.succeed({ data: [{ session }] }),
        pending: () => Effect.succeed([]),
        background: () => Effect.succeed([]),
        active: () => Effect.succeed({}),
        handoffs: () => listed.data,
      },
      {},
    ),
  )
  const entry = page.data[0]
  expect(entry?.browserResourceID).toBe("chrome:browse:github-login")
  const push = body(
    {
      kind: "browser",
      ref: {
        sessionID: session.id,
        title: "Live Activity no iOS",
        project: "opencode2-live-activity",
        directory: session.location.directory,
      },
      requestID: listed.data[0]!.id,
      text: listed.data[0]!.message,
      resourceID: "chrome:browse:github-login",
    },
    "mac-principal",
  )
  if (process.env.UPDATE_FIXTURES) {
    await write("navigation-entry", entry)
    await write("push-browser", push)
  }
  expect(Schema.decodeUnknownSync(Navigation.Info)(await fixture("navigation-entry"))).toBeDefined()
  expect(entry).toEqual(await fixture("navigation-entry"))
  expect(push).toEqual(await fixture("push-browser"))
})
