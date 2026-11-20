import { Database } from "bun:sqlite"
import { afterEach, describe, expect, test } from "bun:test"
import { createCore } from "../src/bancada/daemon/core"
import type { Launcher } from "../src/bancada/daemon/executor"
import { makeLink, type Link } from "../src/bancada/daemon/link"

// The link of a machine against a hub played by a small HTTP server: what goes over the wire and how often.
const idle: Launcher = {
  start: async () => {},
  status: async () => ({ state: "rodando" }),
  cancel: async () => {},
  stop: async () => {},
  reap: async () => {},
  held: () => false,
  cleanup: async () => {},
}
const opened: { servers: ReturnType<typeof Bun.serve>[]; links: Link[] } = { servers: [], links: [] }
afterEach(async () => {
  await Promise.all(opened.links.splice(0).map((link) => link.stop().catch(() => undefined)))
  opened.servers.splice(0).forEach((server) => void server.stop(true))
})

/** A machine (not the hub) linked to `answer`, which plays the hub's server; counts the calls. */
function linked(answer: (input: unknown) => Response) {
  const calls: unknown[] = []
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: async (request) => {
      const body = (await request.json()) as { input: unknown }
      calls.push(body.input)
      return answer(body.input)
    },
  })
  opened.servers.push(server)
  const core = createCore({
    db: new Database(":memory:"),
    now: () => Date.now(),
    random: () => crypto.randomUUID(),
    machine: {
      machineID: "m-mac",
      instanceID: "i-mac",
      name: "Mac",
      platform: "darwin",
      hub: false,
      speed: "normal",
      capabilities: {},
      capacity: { memMb: 32_000, cpuMilli: 8_000, builds: 1, android: 0, ios: 0 },
    },
    launcher: idle,
    log: () => {},
  })
  const link = makeLink({ target: `http://127.0.0.1:${server.port}`, password: "secret", core, log: () => {} })
  opened.links.push(link)
  void link.run()
  return { core, calls }
}

describe("the link to the hub", () => {
  test("a hub that answers at once without confirming what the machine wrote is called with growing waits", async () => {
    // A well-formed answer that never acknowledges the machine's `hello`.
    const { calls } = linked(() =>
      Response.json({ output: { protocol: 1, out: { stream: "h", base: 0, messages: [] }, ack: null } }),
    )
    await Bun.sleep(2_500)
    // Without the rule: thousands of calls in this time (16 725 in 2 s in the review's probe).
    expect(calls.length).toBeGreaterThanOrEqual(2)
    expect(calls.length).toBeLessThanOrEqual(3)
  })

  test("an answer of another protocol is a refusal by name, read before its shape; the machine is alone at once", async () => {
    const { core, calls } = linked(() => Response.json({ output: { protocol: 2, whatever: true } }))
    await Bun.sleep(300)
    expect(calls.length).toBe(1)
    // The core sees it in its next round.
    await core.tick()
    expect(core.hub()).toEqual({
      state: "unavailable",
      since: expect.any(Number),
      reason: "o hub fala outra versão do protocolo da Bancada",
    })
    expect(core.alerts().map((alert) => alert.id)).toEqual(["hub:protocol_mismatch", "hub:fora"])
  })

  test("a refusal by name in the hub's RPC error reaches the core; a wrong password too", async () => {
    const taken = linked(() =>
      Response.json(
        { _tag: "RpcError", type: "machine_taken", message: "the machine m-mac is Outro's", data: {} },
        { status: 400 },
      ),
    )
    const password = linked(() => new Response(null, { status: 401 }))
    await Bun.sleep(300)
    expect(taken.core.alerts().map((alert) => alert.text)).toEqual([
      "o hub já tem esta máquina registrada por outro servidor: the machine m-mac is Outro's",
    ])
    expect(password.core.alerts().map((alert) => alert.text)).toEqual(["o hub recusou a senha desta máquina"])
  })
})
