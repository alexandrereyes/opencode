import { describe, expect, test } from "bun:test"
import { Effect } from "effect"
import type { identity } from "../src/instance"
import { Instance } from "../src/instance/rpc"
import { storage } from "./fixture/storage"

// The plugin loader evaluates the plugin module again for every Location; two query strings give two evaluations.
const evaluate = (instance: string): Promise<{ readonly identity: typeof identity }> =>
  import(`../src/instance/index.ts?${instance}`)

const env = { OPENCODE_HOST_NAME: "Linux BRS" }

describe("custom.instance", () => {
  test("publishes one read method", () => {
    expect(Instance.Definition.id).toBe("custom.instance")
    expect(Object.keys(Instance.Definition.methods)).toEqual(["get"])
  })

  test("keeps one ID per storage: across reads, plugin instances and restarts", async () => {
    const [first, second] = await Promise.all([evaluate("first"), evaluate("second")])
    expect(first.identity).not.toBe(second.identity)
    const shared = storage()
    // Two Locations asking at once on a new server still agree.
    const [a, b] = await Effect.runPromise(
      Effect.all([first.identity(shared, env), second.identity(shared, env)], { concurrency: "unbounded" }),
    )
    expect(a.instanceID).toMatch(/^[0-9a-f-]{36}$/)
    expect(b.instanceID).toBe(a.instanceID)
    expect((await Effect.runPromise(first.identity(shared, env))).instanceID).toBe(a.instanceID)
    // A restarted server reads what the database kept; another server has its own.
    const restarted = await Effect.runPromise(second.identity(storage(shared.values), env))
    expect(restarted.instanceID).toBe(a.instanceID)
    expect((await Effect.runPromise(first.identity(storage(), env))).instanceID).not.toBe(a.instanceID)
  })

  test.each([
    ["1", true],
    [" 1 ", true],
    [undefined, false],
    ["", false],
    ["0", false],
    ["true", false],
  ] as const)("OPENCODE_HUB=%p declares the hub: %p", async (value, hub) => {
    const { identity } = await evaluate("hub")
    const read = await Effect.runPromise(identity(storage(), { ...env, OPENCODE_HUB: value }))
    expect(read.hub).toBe(hub)
  })

  test("names the server as OPENCODE_HOST_NAME does, in contract version 1", async () => {
    const { identity } = await evaluate("name")
    const read = await Effect.runPromise(identity(storage(), { OPENCODE_HOST_NAME: "  Linux BRS " }))
    expect(read).toEqual({ version: 1, instanceID: read.instanceID, name: "Linux BRS", hub: false })
  })
})
