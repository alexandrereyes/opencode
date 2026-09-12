import { expect, test } from "bun:test"
import { OpenCode } from "@opencode/client/promise"
import { Project } from "@opencode/schema/project"
import { createEffect, createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { Snippets } from "@opencode/plugin-app-custom/snippets/rpc"
import { isSnippetConflict } from "@/settings/snippets/model"
import { createServerSnippets } from "@/settings/snippets/server"

const base = {
  id: "global",
  name: "review",
  description: "Review code",
  aliases: ["audit"],
  content: "Review carefully.",
} satisfies Snippets.Info

test("uses the real RPC client for CRUD, cross-Location events, conflicts, and reconnect refresh", async () => {
  const encoder = new TextEncoder()
  const streamReady = Promise.withResolvers<void>()
  const waiting = new Set<{ count: number; resolve: () => void }>()
  const requests: { method: string; input: unknown }[] = []
  const [connection, setConnection] = createStore<{ status: "connected" | "reconnecting"; epoch: number }>({
    status: "connected",
    epoch: 1,
  })
  const state: { items: Snippets.Info[]; events?: ReadableStreamDefaultController<Uint8Array> } = {
    items: [base],
  }
  let lists = 0
  const listed = (count: number) => {
    if (lists >= count) return Promise.resolve()
    return new Promise<void>((resolve) => waiting.add({ count, resolve }))
  }
  const fetcher: typeof fetch = Object.assign(
    async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init)
      const url = new URL(request.url)
      if (url.pathname === "/api/event") {
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              state.events = controller
              controller.enqueue(encoder.encode('data: {"id":"evt_connected","type":"server.connected","data":{}}\n\n'))
              streamReady.resolve()
            },
          }),
          { headers: { "content-type": "text/event-stream" } },
        )
      }
      const body = await request.json()
      if (typeof body !== "object" || body === null || !("input" in body)) throw new Error("Missing RPC input")
      requests.push({ method: url.pathname.split("/").at(-1) ?? "", input: body.input })
      if (url.pathname.endsWith("/list")) {
        lists++
        for (const entry of waiting) {
          if (lists < entry.count) continue
          waiting.delete(entry)
          entry.resolve()
        }
        return Response.json({ output: { items: state.items } })
      }
      if (url.pathname.endsWith("/save")) {
        const snippet = Snippets.Info.make(body.input)
        if (
          state.items.some((item) => item.id !== snippet.id && item.name.toLowerCase() === snippet.name.toLowerCase())
        )
          return Response.json(
            { _tag: "RpcError", type: "conflict", message: "duplicate", data: { name: snippet.name } },
            { status: 400 },
          )
        state.items = [...state.items.filter((item) => item.id !== snippet.id), snippet]
        return Response.json({ output: snippet })
      }
      if (url.pathname.endsWith("/remove")) {
        if (typeof body.input !== "object" || body.input === null || !("id" in body.input))
          throw new Error("Missing snippet ID")
        state.items = state.items.filter((item) => item.id !== body.input.id)
        return Response.json({ output: {} })
      }
      throw new Error(`Unexpected request: ${request.method} ${url.pathname}`)
    },
    { preconnect() {} },
  )

  await createRoot(async (dispose) => {
    try {
      const catalog = createServerSnippets({
        api: OpenCode.make({ baseUrl: "http://snippets.test", fetch: fetcher }),
        connection: { status: () => connection.status, epoch: () => connection.epoch },
      })
      await Promise.all([listed(1), streamReady.promise])
      await new Promise<void>((resolve) => createEffect(() => catalog.list().length === 1 && resolve()))
      expect(catalog.list()).toEqual([base])

      const remote = { ...base, id: "remote", name: "remote", project: Project.ID.make("project") }
      state.items = [...state.items, remote]
      state.events?.enqueue(
        encoder.encode(
          'data: {"id":"evt_remote","created":1,"type":"rpc.custom.snippets.updated","location":{"directory":"/other"},"data":{}}\n\n',
        ),
      )
      await listed(2)
      await new Promise<void>((resolve) => createEffect(() => catalog.list().length === 2 && resolve()))
      expect(catalog.list()).toEqual([base, remote])

      const saved = { ...base, id: "saved", name: "saved" }
      await catalog.save(saved)
      expect(catalog.list()).toEqual([base, remote, saved])
      await catalog.remove(saved.id)
      expect(catalog.list()).toEqual([base, remote])

      const conflict = await catalog.save({ ...base, id: "duplicate", name: "REVIEW" }).then(
        () => undefined,
        (error: unknown) => error,
      )
      expect(isSnippetConflict(conflict)).toBe(true)

      const beforeReconnect = lists
      state.items = [remote]
      setConnection({ status: "reconnecting", epoch: 2 })
      setConnection("status", "connected")
      await listed(beforeReconnect + 1)
      await new Promise<void>((resolve) => createEffect(() => catalog.list().length === 1 && resolve()))
      expect(catalog.list()).toEqual([remote])
      expect(requests.map((request) => request.method)).toEqual([
        "list",
        "list",
        "save",
        "list",
        "remove",
        "list",
        "save",
        "list",
      ])
    } finally {
      dispose()
    }
  })
})
