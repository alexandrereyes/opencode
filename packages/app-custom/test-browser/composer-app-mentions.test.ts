import { describe, expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import type { AppMentions } from "@opencode/plugin-app-custom/rpc"
import { createAppMentions } from "@/composer/app-mentions"

const safari = { server: "codex-computer-use", name: "Safari", bundleID: "com.apple.Safari", running: true }
const connected = (...names: string[]) => names.map((name) => ({ name, status: { status: "connected" } }))

function setup(server: string, initial: ReturnType<typeof connected> | undefined) {
  const [state, setState] = createStore({ open: false, mcp: initial })
  const calls: Array<PromiseWithResolvers<readonly AppMentions.App[]>> = []
  const list = () => {
    const call = Promise.withResolvers<readonly AppMentions.App[]>()
    calls.push(call)
    return call.promise
  }
  return createRoot((dispose) => {
    const apps = createAppMentions({
      target: () => ({ server, directory: "/repo", mcp: state.mcp }),
      open: () => state.open,
      list,
    })
    return { apps, calls, setState, dispose }
  })
}

describe("app mentions", () => {
  test("loads once the app MCP connects and shares the listing across composers", async () => {
    // The listing cache is module-wide; each test (and rerun) uses its own server key.
    const server = crypto.randomUUID()
    const first = setup(server, connected("codex-computer-use"))
    expect(first.calls).toHaveLength(1)
    first.calls[0].resolve([safari])
    await Promise.resolve()
    expect(first.apps()).toEqual([safari])

    const second = setup(server, connected("codex-computer-use"))
    second.setState("open", true)
    expect(second.calls).toHaveLength(0)
    expect(second.apps()).toEqual([safari])
    first.dispose()
    second.dispose()
  })

  test("lists nothing without app MCPs and relists after reconnecting", async () => {
    const composer = setup(crypto.randomUUID(), connected("blender"))
    composer.setState("open", true)
    expect(composer.calls).toHaveLength(0)
    expect(composer.apps()).toEqual([])

    composer.setState("mcp", connected("codex-computer-use"))
    composer.calls[0].resolve([safari])
    await Promise.resolve()
    expect(composer.apps()).toEqual([safari])

    composer.setState("mcp", connected("codex-computer-use", "safari-devtools"))
    expect(composer.calls).toHaveLength(2)
    expect(composer.apps()).toEqual([])
    composer.dispose()
  })

  test("waits for `@` while the MCP list is unknown and keeps listing after a failure", async () => {
    const composer = setup(crypto.randomUUID(), undefined)
    expect(composer.calls).toHaveLength(0)
    composer.setState("open", true)
    expect(composer.calls).toHaveLength(1)
    composer.calls[0].reject(new Error("offline"))
    await Promise.resolve()
    await Promise.resolve()
    expect(composer.apps()).toEqual([])
    composer.dispose()
  })
})
