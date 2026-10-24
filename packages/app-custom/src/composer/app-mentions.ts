import { createEffect, createMemo, untrack } from "solid-js"
import { createStore } from "solid-js/store"
import { AppMentions } from "@opencode/plugin-app-custom/rpc"

// Listing Computer Use apps takes seconds. Composers share one listing per server and Location, loaded
// as soon as its connected app MCPs are known, so typing `@` never waits for it. A different
// connected set (connecting, disconnecting or reconnecting) lists again.
const [cache, setCache] = createStore<Record<string, { set: string; apps: readonly AppMentions.App[]; at: number }>>({})
const pending = new Map<string, string>()
const fresh = 60_000
const retry = 5_000
const servers: string[] = [AppMentions.ComputerUse.server, AppMentions.SafariDevTools.server]

export function createAppMentions(input: {
  target: () =>
    | { server: string; directory: string; mcp: readonly { name: string; status: { status: string } }[] | undefined }
    | undefined
  open: () => boolean
  list: (directory: string) => Promise<readonly AppMentions.App[]>
}) {
  const key = createMemo(
    () => {
      const target = input.target()
      if (!target) return
      const connected = target.mcp
        ?.filter((server) => servers.includes(server.name) && server.status.status === "connected")
        .map((server) => server.name)
        .sort()
      if (connected?.length === 0) return
      return {
        scope: JSON.stringify([target.server, target.directory]),
        // Without an MCP list yet, load on `@` and let the server decide.
        set: connected?.join(",") ?? "",
        known: connected !== undefined,
        directory: target.directory,
      }
    },
    undefined,
    {
      equals: (previous, next) =>
        previous === next ||
        (!!previous &&
          !!next &&
          previous.scope === next.scope &&
          previous.set === next.set &&
          previous.known === next.known),
    },
  )

  createEffect(() => {
    const current = key()
    const open = input.open()
    if (!current || !(current.known || open)) return
    untrack(() => load(current.scope, current.set, current.directory))
  })

  function load(scope: string, set: string, directory: string) {
    if (pending.get(scope) === set) return
    const entry = cache[scope]
    if (entry?.set === set && Date.now() - entry.at < fresh) return
    pending.set(scope, set)
    const settle = (apps: readonly AppMentions.App[], at: number) => {
      if (pending.get(scope) !== set) return
      pending.delete(scope)
      setCache(scope, { set, apps, at })
    }
    void input.list(directory).then(
      (apps) => settle(apps, Date.now()),
      () => settle(cache[scope]?.set === set ? cache[scope].apps : [], Date.now() - fresh + retry),
    )
  }

  return () => {
    const current = key()
    const entry = current && cache[current.scope]
    return entry && entry.set === current.set ? entry.apps : []
  }
}
