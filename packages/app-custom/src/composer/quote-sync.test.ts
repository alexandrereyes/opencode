import { describe, expect, test } from "bun:test"
import { createRoot } from "solid-js"
import type { Quotes } from "@opencode/plugin-app-custom/quotes/rpc"
import { createChatQuoteSync, type ChatQuoteApi } from "./quote-sync"
import { createMemoryComposerState } from "./state"

const selection = { messageID: "msg_answer", partID: "prt_text", text: "Rodando: nada." }

// In-memory stand-in for the plugin: last write wins per quote, sent IDs are tombstoned.
function server(options: { supported?: boolean } = {}) {
  const state = { revision: 0, quotes: [] as Quotes.Quote[], sent: new Set<string>() }
  const calls: { method: string; input?: unknown }[] = []
  const bump = () => ++state.revision
  const write = (input: Quotes.QuoteInput): Quotes.Quote => {
    const revision = bump()
    const existing = state.quotes.find((quote) => quote.id === input.id)
    const quote: Quotes.Quote = {
      ...input,
      attachments: (input.attachments ?? []).map((id) => ({ id, mime: "image/png", size: 3 })),
      createdAt: existing?.createdAt ?? revision,
      updatedAt: revision,
      revision,
    }
    state.quotes = existing
      ? state.quotes.map((item) => (item.id === input.id ? quote : item))
      : [...state.quotes, quote]
    return quote
  }
  const list = (): Quotes.State => ({
    sessionID: "ses_test" as Quotes.State["sessionID"],
    revision: state.revision,
    quotes: state.quotes,
    dismissed: [],
  })
  const api: ChatQuoteApi = {
    info: async () => {
      calls.push({ method: "info" })
      if (options.supported === false) throw { type: "rpc.method_not_found", message: "Unknown RPC method" }
      return { version: 1 }
    },
    list: async () => list(),
    save: async (input) => {
      calls.push({ method: "save", input })
      if (state.sent.has(input.id)) throw { type: "already_sent", data: { ids: [input.id] } }
      return { revision: state.revision, quote: write(input) }
    },
    remove: async (id) => {
      calls.push({ method: "remove", input: id })
      state.quotes = state.quotes.filter((quote) => quote.id !== id)
      bump()
    },
    clear: async (ids) => {
      calls.push({ method: "clear", input: ids })
      ids.forEach((id) => state.sent.add(id))
      state.quotes = state.quotes.filter((quote) => !ids.includes(quote.id))
      bump()
    },
    import: async (quotes) => {
      calls.push({ method: "import", input: quotes })
      const fresh = quotes.filter((quote) => !state.quotes.some((item) => item.id === quote.id))
      fresh.forEach(write)
      return { state: list(), imported: fresh.map((quote) => quote.id) }
    },
    upload: async (input) => {
      calls.push({ method: "upload", input })
      return { id: "a".repeat(64), mime: input.mime, size: 3 }
    },
    attachment: async (id) => ({ id, mime: "image/png", size: 3, data: "AAAA" }),
  }
  return { state, calls, api, write, bump }
}

function setup(api: ChatQuoteApi) {
  return createRoot((dispose) => {
    const composer = createMemoryComposerState()
    const sync = createChatQuoteSync({ quotes: composer.quotes, ready: () => undefined, api })
    return { composer, sync, dispose: () => (sync.dispose(), dispose()) }
  })
}

const methods = (calls: { method: string }[]) => calls.map((call) => call.method)

describe("chat quote server sync", () => {
  test("keeps local drafts when the server has no custom.quotes", async () => {
    const remote = server({ supported: false })
    const f = setup(remote.api)
    f.composer.quotes.add(selection)
    await f.sync.refresh()
    expect(f.sync.mode()).toBe("local")
    expect(f.composer.quotes.server.active()).toBe(false)
    expect(f.composer.quotes.all()).toHaveLength(1)
    expect(f.composer.quotes.server.local()).toHaveLength(1)
    expect(methods(remote.calls)).toEqual(["info"])
    f.dispose()
  })

  test("imports local drafts once, keeping their IDs, then mirrors the server", async () => {
    const remote = server()
    const f = setup(remote.api)
    const id = f.composer.quotes.add(selection)
    f.composer.quotes.update(id, "local comment")
    await f.sync.refresh()
    expect(f.sync.mode()).toBe("server")
    expect(f.composer.quotes.server.local()).toEqual([])
    expect(f.composer.quotes.all().map((quote) => [quote.id, quote.comment])).toEqual([[id, "local comment"]])
    await f.sync.refresh()
    expect(methods(remote.calls).filter((method) => method === "import")).toHaveLength(1)
    f.dispose()
  })

  test("pushes edits and removals, applies remote changes and protects the open editor", async () => {
    const remote = server()
    const f = setup(remote.api)
    await f.sync.refresh()
    const id = f.composer.quotes.add(selection)
    f.composer.quotes.update(id, "first")
    await f.sync.flush()
    expect(remote.state.quotes.map((quote) => quote.comment)).toEqual(["first"])

    remote.write({ ...remote.state.quotes[0]!, comment: "edited on the iPhone", attachments: [] })
    await f.sync.refresh()
    expect(f.composer.quotes.all()[0]?.comment).toBe("first")
    f.composer.quotes.editor.close()
    remote.write({ ...remote.state.quotes[0]!, comment: "edited again", attachments: [] })
    await f.sync.refresh()
    expect(f.composer.quotes.all()[0]?.comment).toBe("edited again")

    remote.write({
      id: "from-ios",
      ...selection,
      comment: "new",
      anchor: { start: 0, end: 3, exact: "**R", coordinate: "source" },
    })
    await f.sync.refresh()
    expect(f.composer.quotes.all().map((quote) => quote.id)).toEqual([id, "from-ios"])
    expect(f.composer.quotes.editor.current()).toBe("")

    f.composer.quotes.remove("from-ios")
    await f.sync.flush()
    expect(remote.state.quotes.map((quote) => quote.id)).toEqual([id])
    remote.state.quotes = []
    remote.bump()
    await f.sync.refresh()
    expect(f.composer.quotes.all()).toEqual([])
    f.dispose()
  })

  test("clears sent quotes only after admission and restores them on failure without writes", async () => {
    const remote = server()
    const f = setup(remote.api)
    await f.sync.refresh()
    const id = f.composer.quotes.add(selection)
    f.composer.quotes.update(id, "send me")
    await f.sync.flush()
    const sent = f.composer.quotes.all().map((quote) => ({ ...quote }))
    remote.calls.length = 0

    f.composer.quotes.sending([id])
    await f.sync.refresh()
    expect(f.composer.quotes.all()).toEqual([])
    f.composer.quotes.replace(sent)
    await f.sync.flush()
    expect(f.composer.quotes.all().map((quote) => quote.id)).toEqual([id])
    expect(methods(remote.calls)).toEqual([])

    f.composer.quotes.sending([id])
    f.composer.quotes.sent([id])
    await f.sync.flush()
    expect(methods(remote.calls)).toEqual(["clear"])
    expect(remote.state.quotes).toEqual([])
    f.dispose()
  })

  test("quotes restored from a sent message become new drafts; stale edits of sent ones are dropped", async () => {
    const remote = server()
    const f = setup(remote.api)
    await f.sync.refresh()
    remote.state.sent.add("sent-before")
    f.composer.quotes.replace([{ ...selection, id: "sent-before", comment: "restored by revert" }])
    await f.sync.flush()
    expect(remote.state.quotes.map((quote) => quote.comment)).toEqual(["restored by revert"])
    expect(remote.state.quotes[0]?.id).not.toBe("sent-before")
    expect(f.composer.quotes.all()[0]?.id).toBe(remote.state.quotes[0]?.id)

    const id = remote.state.quotes[0]!.id
    remote.state.sent.add(id)
    f.composer.quotes.update(id, "late edit")
    await f.sync.flush()
    expect(f.composer.quotes.all()).toEqual([])
    f.dispose()
  })

  test("uploads pasted images and references them by attachment ID", async () => {
    const remote = server()
    const f = setup(remote.api)
    await f.sync.refresh()
    const id = f.composer.quotes.add(selection)
    f.composer.quotes.update(id, "[shot.png]", [
      { type: "text", content: "[shot.png]", start: 0, end: 10 },
      {
        type: "image",
        id: "img",
        filename: "shot.png",
        sourcePath: undefined,
        mime: "image/png",
        mention: { text: "[shot.png]", start: 0, end: 10 },
        blob: { id: "local-blob", url: "data:image/png;base64,AAAA" },
      },
    ])
    await f.sync.flush()
    expect(remote.calls.find((call) => call.method === "upload")?.input).toMatchObject({ data: "AAAA" })
    const saved = remote.state.quotes[0]!
    expect(saved.attachments.map((item) => item.id)).toEqual(["a".repeat(64)])
    expect(saved.commentPrompt?.[1]).toMatchObject({ type: "image", blob: { id: "a".repeat(64), url: "" } })
    f.dispose()
  })

  test("history previews do not publish and return to the live drafts", async () => {
    const remote = server()
    const f = setup(remote.api)
    await f.sync.refresh()
    f.composer.quotes.add(selection)
    await f.sync.flush()
    remote.calls.length = 0
    f.composer.quotes.preview([{ ...selection, id: "history", comment: "old" }], false)
    expect(f.composer.quotes.all().map((quote) => quote.id)).toEqual(["history"])
    f.composer.quotes.update("history", "changed while browsing")
    await f.sync.flush()
    expect(methods(remote.calls)).toEqual([])
    f.composer.quotes.preview([], true)
    expect(f.composer.quotes.all()).toHaveLength(1)
    f.dispose()
  })
})
