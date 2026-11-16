import { expect, test } from "bun:test"
import { Effect, Exit, Scope } from "effect"
import { browseOwner } from "../src/browser-handoff/calls"
import { makeBrowseResources } from "../src/resources/browse"
import type { Lock, Upsert } from "../src/resources/hub/hub"
import { HubError } from "../src/resources/supervisor"

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect)
const S = "ses_agent"
const owner = browseOwner(S)
const cdp = "http://127.0.0.1:19988"

/** The plugin's side of a session's browse resource, over a fake hub. */
async function setup(
  options: {
    readonly locks?: Lock[]
    /** Replaces the hub's answers (a hub that is down, hangs or refuses). */
    readonly hub?: "down" | "hangs" | "remote unreachable"
  } = {},
) {
  const scope = await run(Scope.make())
  const upserts: Upsert[] = []
  let asked = 0
  const broken = async () => {
    if (options.hub === "down") throw new HubError("hub", "Resources hub unavailable")
    if (options.hub === "hangs") await new Promise(() => undefined)
  }
  const browse = makeBrowseResources({
    hub: {
      upsert: async (input) => {
        upserts.push(input)
        await broken()
        return {} as never
      },
      locks: async () => {
        asked++
        await broken()
        return options.hub === "remote unreachable" ? undefined : (options.locks ?? [])
      },
    },
    family: () => Effect.succeed({ root: "ses_root" }),
    scope,
    endpoint: async () => cdp,
    graceMs: 30,
    timeouts: { locks: 50, write: 50 },
  })
  return { browse, upserts, asked: () => asked, close: () => run(Scope.close(scope, Exit.void)) }
}
const call = (id: string, tool: string, input: object, sessionID = S) => ({ tool, sessionID, id, input, agent: "build" })
const done = (id: string, tool: string, input: object, output?: unknown) => ({
  ...call(id, tool, input),
  status: "completed" as const,
  result: { output },
})
const shown = (upserts: Upsert[]) =>
  upserts.map((item) => [item.meta.kind === "chrome" ? item.meta.targetID : undefined, item.activity?.running])

test("a call that runs past the grace period registers its tab as in use, and its end closes the activity", async () => {
  const { browse, upserts, close } = await setup()
  await run(browse.before(call("c1", "browse_type", { tab: 7, text: "senha-secreta" })))
  expect(upserts).toEqual([])
  await Bun.sleep(80)
  expect(upserts).toEqual([
    {
      kind: "chrome",
      meta: { kind: "chrome", cdp, browse: owner, targetID: "7" },
      owner: { sessionID: S, rootSessionID: "ses_root", agent: "build" },
      used: true,
      activity: { call: "c1", command: "browse type", running: true },
    },
  ])
  await run(browse.after(done("c1", "browse.type", { tab: 7, text: "senha-secreta" }, { typed: 13 })))
  expect(upserts.at(-1)?.activity).toEqual({ call: "c1", command: "browse type", running: false })
  // The arguments never reach the hub.
  expect(JSON.stringify(upserts)).not.toContain("senha")
  await close()
})

test("the tab a call opens comes from its result, also with browse's warnings after it; failures register nothing new", async () => {
  const { browse, upserts, close } = await setup()
  // `navigate` without `tab` opens one; OpenCode passes text it cannot parse as JSON (a warning follows) as is.
  await run(browse.before(call("n", "browse_navigate", { url: "https://loja.example" })))
  const text = `{\n  "url": "https://loja.example/",\n  "title": "Loja",\n  "tab": 9\n}\nWarning: The page has a cookie banner`
  await run(browse.after(done("n", "browse_navigate", { url: "https://loja.example" }, text)))
  await run(browse.before(call("t", "browse_tabs", { action: "new" })))
  await run(browse.after(done("t", "browse_tabs", { action: "new" }, { tab: 11, url: "about:blank" })))
  expect(shown(upserts)).toEqual([
    ["9", false],
    ["11", false],
  ])
  // A quick call that failed, or closed tabs, gives none; a long one that failed only closes its activity.
  await run(browse.before(call("f", "browse_click", { tab: 9, x: 1, y: 1 })))
  await run(browse.after({ ...call("f", "browse_click", { tab: 9, x: 1, y: 1 }), status: "error" }))
  await run(browse.before(call("x", "browse_tabs", { action: "close", tab: 9 })))
  await run(browse.after(done("x", "browse_tabs", { action: "close", tab: 9 }, { closed: [9] })))
  await run(browse.before(call("w", "browse_wait_for", { tab: 11, text: "Pronto" })))
  await Bun.sleep(80)
  await run(browse.after({ ...call("w", "browse_wait_for", { tab: 11, text: "Pronto" }), status: "error" }))
  expect(shown(upserts).slice(2)).toEqual([
    ["11", true],
    [undefined, false],
  ])
  await close()
})

test("the tools that touch no tab are never checked nor registered", async () => {
  const { browse, upserts, asked, close } = await setup()
  for (const [tool, input] of [
    ["browse_status", {}],
    ["browse_settings", { set: { humanInput: "off" } }],
    ["browse_tabs", {}],
    ["browse.tabs", { action: "list" }],
  ] as const) {
    await run(browse.before(call("g", tool, input)))
    await run(browse.after(done("g", tool, input, { tabs: [{ tab: 3 }] })))
  }
  await Bun.sleep(80)
  expect(upserts).toEqual([])
  expect(asked()).toBe(0)
  await close()
})

test("while Alexandre controls a session's browse tab its calls are refused; other sessions' go on", async () => {
  const lock: Lock = {
    id: `chrome:browse:${owner}`,
    kind: "chrome",
    label: "Navegador · loja.example",
    meta: { kind: "chrome", cdp, browse: owner, targetID: "7" },
    expiresAt: 0,
  }
  const { browse, upserts, close } = await setup({ locks: [lock] })
  const refused = async (tool: string, input: object, sessionID = S) => {
    const exit = await Effect.runPromiseExit(browse.before(call("x", tool, input, sessionID)))
    return Exit.isFailure(exit) ? JSON.stringify(exit.cause) : undefined
  }
  // Any tab of the session, the one he holds or not: the agent would only switch tabs around the lock.
  expect(await refused("browse_click", { tab: 7, x: 1, y: 1 })).toContain("Alexandre está controlando pelo app")
  expect(await refused("browse_navigate", { url: "https://x.example" })).toContain("pela CLI do browse")
  expect(await refused("browse_handoff", { tab: 8, message: "Entre" })).toBeDefined()
  expect(await refused("browse_tabs", { action: "close", tab: 7 })).toBeDefined()
  // What touches no tab, and other sessions, go through.
  expect(await refused("browse_tabs", { action: "list" })).toBeUndefined()
  expect(await refused("browse_status", {})).toBeUndefined()
  expect(await refused("shell", { command: "ls" })).toBeUndefined()
  expect(await refused("browse_click", { tab: 7, x: 1, y: 1 }, "ses_other")).toBeUndefined()
  await Bun.sleep(80)
  expect(upserts.map((item) => item.meta.kind === "chrome" && item.meta.browse)).toEqual([browseOwner("ses_other")])
  await close()
})

test("a hub that is down, hangs or cannot be reached never refuses or holds the agent's browse calls", async () => {
  for (const hub of ["down", "hangs", "remote unreachable"] as const) {
    const { browse, upserts, close } = await setup({ hub })
    const started = Date.now()
    // Every step of a call's life goes through: the lock check, the registration while it runs, its end.
    for (const [id, tool, input] of [
      ["c1", "browse_click", { tab: 7, x: 1, y: 1 }],
      ["c2", "browse_navigate", { url: "https://x.example" }],
    ] as const) {
      expect(Exit.isSuccess(await Effect.runPromiseExit(browse.before(call(id, tool, input))))).toBe(true)
      await Bun.sleep(80)
      expect(Exit.isSuccess(await Effect.runPromiseExit(browse.after(done(id, tool, input, { tab: 7 }))))).toBe(true)
    }
    // Each wait is cut short: two calls with their grace periods, not the hub's own timeouts.
    expect(Date.now() - started).toBeLessThan(1_500)
    // The writes were attempted all the same (a hub that comes back gets them).
    expect(upserts.length).toBeGreaterThanOrEqual(4)
    await close()
  }
})
