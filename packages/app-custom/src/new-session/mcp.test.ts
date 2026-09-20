import { describe, expect, test } from "bun:test"
import { applyDraftMcpStates } from "./mcp"

describe("draft MCP preparation", () => {
  test("awaits an in-flight destination toggle before checking readiness", async () => {
    let release!: (ready: boolean) => void
    const pending = new Promise<boolean>((resolve) => {
      release = resolve
    })
    let listed = false
    const result = applyDraftMcpStates({
      pending,
      states: { docs: true },
      list: async () => {
        listed = true
        return [{ name: "docs", status: { status: "connected" } }]
      },
      change: async () => true,
    })
    await Promise.resolve()
    expect(listed).toBe(false)
    release(true)
    expect(await result).toEqual({ ready: true })
  })

  test("applies every override and verifies the resulting destination state", async () => {
    const states = new Map<string, "connected" | "disabled">([
      ["docs", "disabled"],
      ["search", "connected"],
    ])
    const changed: Array<[string, boolean]> = []
    const result = await applyDraftMcpStates({
      states: { docs: true, search: false },
      list: async () => [...states].map(([name, status]) => ({ name, status: { status } })),
      change: async (name, enabled) => {
        changed.push([name, enabled])
        states.set(name, enabled ? "connected" : "disabled")
        return true
      },
    })
    expect(changed).toEqual([
      ["docs", true],
      ["search", false],
    ])
    expect(result).toEqual({ ready: true })
  })

  test("refuses unavailable and authentication-blocked destination servers", async () => {
    expect(
      await applyDraftMcpStates({
        states: { missing: true },
        list: async () => [],
        change: async () => true,
      }),
    ).toEqual({ ready: false, issue: "unavailable", name: "missing" })

    let calls = 0
    expect(
      await applyDraftMcpStates({
        states: { docs: true },
        list: async () => {
          calls++
          return calls === 1
            ? [{ name: "docs", status: { status: "disabled" as const } }]
            : [{ name: "docs", status: { status: "needs_auth" as const, error: "Authentication required" } }]
        },
        change: async () => true,
      }),
    ).toEqual({ ready: false, issue: "needs_auth", name: "docs" })
  })
})
