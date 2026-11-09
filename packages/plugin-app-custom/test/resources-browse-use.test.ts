import { expect, test } from "bun:test"
import { Effect, Exit, Scope } from "effect"
import { makeBrowseResources } from "../src/resources/browse"
import type { Lock, Upsert } from "../src/resources/hub/hub"

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect)
const S = "ses_agent"

/** The plugin's side of a browse session's resource, over a fake hub and relay. */
async function setup(
  options: { readonly locks?: Lock[]; readonly found?: string; readonly candidates?: string[] } = {},
) {
  const scope = await run(Scope.make())
  const upserts: Upsert[] = []
  const removed: string[] = []
  const asked: { candidates: readonly string[] }[] = []
  const browse = makeBrowseResources({
    hub: {
      upsert: async (input) => {
        upserts.push(input)
        return {} as never
      },
      remove: async (id) => {
        removed.push(id)
        return {}
      },
      locks: async () => options.locks ?? [],
    },
    current: { candidates: () => options.candidates ?? ["mcp-1a2b3c4d"] },
    find: (candidates) =>
      Effect.sync(() => {
        asked.push({ candidates })
        return options.found
      }),
    family: () => Effect.succeed({ root: "ses_root" }),
    scope,
    now: () => 1_000,
    endpoint: "http://127.0.0.1:19988",
    graceMs: 30,
  })
  return { browse, upserts, removed, asked, close: () => run(Scope.close(scope, Exit.void)) }
}
const call = (id: string, tool: string, input: object) => ({ tool, sessionID: S, id, input, agent: "build" })

test("a call that runs past the grace period registers its session, and its result closes the activity", async () => {
  const { browse, upserts, close } = await setup()
  await run(browse.before(call("c1", "browse_execute", { code: "await page.goto(x)", session: "loja" })))
  expect(upserts).toEqual([])
  await Bun.sleep(80)
  expect(upserts).toEqual([
    {
      kind: "chrome",
      meta: { kind: "chrome", cdp: "http://127.0.0.1:19988", browse: "loja" },
      owner: { sessionID: S, rootSessionID: "ses_root", agent: "build" },
      used: true,
      activity: { call: "c1", command: "browse execute", running: true },
    },
  ])
  await run(
    browse.after({
      ...call("c1", "browse_execute", { session: "loja" }),
      status: "completed",
      result: { output: { session: "loja" } },
    }),
  )
  expect(upserts.at(-1)?.activity).toEqual({ call: "c1", command: "browse execute", running: false })
  // The code never reaches the hub.
  expect(JSON.stringify(upserts)).not.toContain("goto")
  await close()
})

test("a call without `session` registers the one its result names, or the one the relay saw it touch", async () => {
  const quick = await setup()
  await run(quick.browse.before(call("c1", "browse_execute", { code: "1" })))
  await run(
    quick.browse.after({
      ...call("c1", "browse_execute", { code: "1" }),
      status: "completed",
      result: { output: { session: "mcp-1a2b3c4d" } },
    }),
  )
  expect(quick.upserts.map((item) => [item.meta, item.activity?.running])).toEqual([
    [{ kind: "chrome", cdp: "http://127.0.0.1:19988", browse: "mcp-1a2b3c4d" }, false],
  ])
  await Bun.sleep(80)
  // It ended before the grace period: nothing more.
  expect(quick.upserts).toHaveLength(1)
  await quick.close()

  const long = await setup({ found: "mcp-1a2b3c4d" })
  await run(long.browse.before(call("c2", "browse_execute", { code: "await handoff('x')" })))
  await Bun.sleep(80)
  expect(long.asked).toEqual([{ candidates: ["mcp-1a2b3c4d"] }])
  expect(long.upserts.map((item) => item.activity?.running)).toEqual([true])
  // It failed: the session found while it ran gets its activity closed; nothing else is registered.
  await run(long.browse.after({ ...call("c2", "browse_execute", {}), status: "error" }))
  expect(long.upserts.map((item) => [item.meta.kind === "chrome" && item.meta.browse, item.activity?.running])).toEqual(
    [
      ["mcp-1a2b3c4d", true],
      ["mcp-1a2b3c4d", false],
    ],
  )
  await long.close()

  // Unsure: no resource.
  const unsure = await setup({ found: undefined })
  await run(unsure.browse.before(call("c3", "browse_execute", { code: "1" })))
  await Bun.sleep(80)
  await run(unsure.browse.after({ ...call("c3", "browse_execute", {}), status: "error" }))
  expect(unsure.upserts).toEqual([])
  await unsure.close()
})

test("session_new registers its session, session_delete removes it, and global tools touch nothing", async () => {
  const { browse, upserts, removed, close } = await setup()
  await run(browse.before(call("n", "browse_session_new", { allowedOrigins: ["loja.example"] })))
  await run(
    browse.after({
      ...call("n", "browse_session_new", {}),
      status: "completed",
      result: { output: { session: { id: "nova" } } },
    }),
  )
  expect(upserts.map((item) => item.meta)).toEqual([{ kind: "chrome", cdp: "http://127.0.0.1:19988", browse: "nova" }])
  await run(
    browse.after({
      ...call("d", "browse_session_delete", { id: "nova" }),
      status: "completed",
      result: { output: {} },
    }),
  )
  expect(removed).toEqual(["chrome:browse:nova"])
  for (const tool of ["browse_status", "browse_session_list", "browse_session_use", "browse_settings"]) {
    await run(browse.before(call("g", tool, { id: "nova" })))
    await run(
      browse.after({
        ...call("g", tool, { id: "nova" }),
        status: "completed",
        result: { output: { session: "nova" } },
      }),
    )
  }
  expect(upserts).toHaveLength(1)
  await close()
})

test("while Alexandre controls a session the agents' calls on it are refused; others go on", async () => {
  const lock: Lock = {
    id: "chrome:browse:loja",
    kind: "chrome",
    label: "Navegador · loja.example",
    meta: { kind: "chrome", cdp: "http://127.0.0.1:19988", browse: "loja" },
    expiresAt: 0,
  }
  const { browse, upserts, close } = await setup({ locks: [lock], candidates: ["mcp-1a2b3c4d", "loja"] })
  const refused = async (tool: string, input: object) => {
    const exit = await Effect.runPromiseExit(browse.before(call("x", tool, input)))
    return Exit.isFailure(exit) ? JSON.stringify(exit.cause) : undefined
  }
  expect(await refused("browse_execute", { code: "1", session: "loja" })).toContain("Alexandre está controlando")
  expect(await refused("browse_session_reset", { id: "loja" })).toContain('sessão do browse \\"loja\\"')
  expect(await refused("browse_session_delete", { session: "loja" })).toBeDefined()
  expect(await refused("browse_screenshot", { session: "loja" })).toBeDefined()
  // Without `session`, the agent may have it current: refused, saying how to name another.
  expect(await refused("browse_execute", { code: "1" })).toContain("passando `session` com a sessão certa")
  // Another session, a new one, and the tools that touch no tab go through.
  expect(await refused("browse_execute", { code: "1", session: "outra" })).toBeUndefined()
  expect(await refused("browse_session_new", {})).toBeUndefined()
  expect(await refused("browse_session_use", { id: "loja" })).toBeUndefined()
  expect(await refused("browse_status", {})).toBeUndefined()
  expect(await refused("shell", { command: "ls" })).toBeUndefined()
  await Bun.sleep(80)
  expect(upserts.map((item) => item.meta.kind === "chrome" && item.meta.browse)).toEqual(["outra"])
  await close()
})
