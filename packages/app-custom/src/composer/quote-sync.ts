import { createEffect, on, onCleanup } from "solid-js"
import { Option, Schema } from "effect"
import { base64Decode } from "@opencode/util/encode"
import { Quotes } from "@opencode/plugin-app-custom/quotes/rpc"
import { useLanguage } from "@/runtime/i18n/language"
import type { ServerSDK } from "@/runtime/server/client"
import { showToast } from "@/shell/notifications/toast"
import { blobData } from "@/runtime/persistence/drafts"
import { uuid } from "@/runtime/persistence/uuid"
import { Prompt, type ChatQuote, type ImageAttachmentPart } from "./schema"
import type { ComposerState } from "./state"

/** `custom.quotes` bound to one Session; see `packages/plugin-app-custom/docs/quotes.md`. */
export type ChatQuoteApi = {
  info(): Promise<unknown>
  list(): Promise<Quotes.State>
  save(quote: Quotes.QuoteInput): Promise<{ revision: number; quote: Quotes.Quote }>
  remove(id: string): Promise<unknown>
  clear(ids: string[]): Promise<unknown>
  import(quotes: Quotes.QuoteInput[]): Promise<{ state: Quotes.State; imported: readonly string[] }>
  upload(input: { mime: string; filename?: string; data: string }): Promise<Quotes.Attachment>
  attachment(id: string): Promise<Quotes.Attachment & { data: string }>
}

type Failure = { type: string; data?: unknown }

const DEBOUNCE = 400
const decodePrompt = Schema.decodeUnknownOption(Prompt)
const encodePrompt = Schema.encodeSync(Prompt)
const decodeJson = Schema.decodeUnknownSync(Schema.Array(Schema.Json))
const decodeUpdated = Schema.decodeUnknownOption(Schema.Struct({ sessionID: Schema.String, revision: Schema.Number }))

/**
 * Keeps a Session's composer quotes on the server: probes `info`, imports local drafts once, mirrors
 * `list`, and pushes local edits (debounced), removals and sent quotes. Without `custom.quotes` the
 * composer keeps its local drafts.
 */
export function createChatQuoteSync(input: {
  quotes: ComposerState["quotes"]
  ready: () => Promise<unknown> | undefined
  api: ChatQuoteApi
  failed?: (failure: Failure) => void
}) {
  const quotes = input.quotes
  const state = {
    mode: "unknown" as "unknown" | "local" | "server",
    revision: -1,
    starting: undefined as Promise<void> | undefined,
    chain: Promise.resolve(),
    timer: undefined as ReturnType<typeof setTimeout> | undefined,
    disposed: false,
  }
  const known = new Map<string, Quotes.Quote>()
  const dirty = new Set<string>()
  const removing = new Set<string>()
  const sending = new Set<string>()
  const clearing = new Set<string>()
  // Quotes restored from sent messages (revert, an undone queued prompt) reuse sent IDs; they get new ones.
  const adopted = new Set<string>()
  const uploaded = new Map<string, string>()
  const loaded = new Map<string, string>()

  const hooks = {
    changed(id: string) {
      dirty.add(id)
      schedule(DEBOUNCE)
    },
    removed(id: string) {
      dirty.delete(id)
      adopted.delete(id)
      if (known.has(id)) removing.add(id)
      schedule(0)
    },
    replaced(before: ChatQuote[], after: ChatQuote[]) {
      after.forEach((item) => {
        const server = known.get(item.id)
        if (sending.delete(item.id) && server && same(item, server)) return
        if (server && same(item, server)) return
        if (!server) adopted.add(item.id)
        dirty.add(item.id)
      })
      before.filter((item) => !after.some((next) => next.id === item.id)).forEach((item) => hooks.removed(item.id))
      schedule(0)
    },
    sending(ids: string[]) {
      ids.forEach((id) => {
        dirty.delete(id)
        sending.add(id)
      })
    },
    sent(ids: string[]) {
      ids.forEach((id) => {
        sending.delete(id)
        adopted.delete(id)
        clearing.add(id)
      })
      schedule(0)
    },
    flush: () => void flush(),
  }
  const disconnect = quotes.server.connect(hooks)

  function schedule(delay: number) {
    if (state.mode !== "server") return
    clearTimeout(state.timer)
    state.timer = setTimeout(() => void flush(), delay)
  }

  function flush() {
    clearTimeout(state.timer)
    state.timer = undefined
    state.chain = state.chain.then(push).catch((error: unknown) => {
      report(error)
      // Network failures keep the pending work; try again shortly instead of waiting for the next edit.
      if (dirty.size || removing.size || clearing.size) schedule(5_000)
    })
    return state.chain
  }

  async function push() {
    if (state.mode !== "server" || state.disposed) return
    for (const id of [...removing]) {
      await input.api.remove(id)
      removing.delete(id)
      known.delete(id)
    }
    if (clearing.size) {
      const ids = [...clearing]
      await input.api.clear(ids)
      ids.forEach((id) => {
        clearing.delete(id)
        known.delete(id)
      })
    }
    // A rejected save can queue one retry (new ID, re-uploaded attachment); bound the rounds.
    for (let round = 0; round < 3 && dirty.size; round++) {
      for (const id of [...dirty]) {
        const item = quotes.server.live().find((quote) => quote.id === id)
        dirty.delete(id)
        if (!item) continue
        const saved = await toInput(item)
          .then((quote) => input.api.save(quote))
          .catch((error: unknown) => error)
        if (isSaved(saved)) {
          known.set(id, saved.quote)
          adopted.delete(id)
          continue
        }
        await rejected(id, saved)
      }
    }
  }

  async function rejected(id: string, error: unknown) {
    if (!isFailure(error)) {
      dirty.add(id)
      throw error
    }
    if (error.type === "already_sent" && adopted.has(id)) {
      adopted.delete(id)
      const next = uuid()
      quotes.server.apply(quotes.server.live().map((quote) => (quote.id === id ? { ...quote, id: next } : quote)))
      dirty.add(next)
      return
    }
    if (error.type === "already_sent") {
      quotes.server.apply(quotes.server.live().filter((quote) => quote.id !== id))
      return
    }
    if (error.type === "attachment_missing") {
      const missing = new Set(readIds(error.data))
      uploaded.forEach((server, local) => missing.has(server) && uploaded.delete(local))
      dirty.add(id)
      return
    }
    if (unsupported(error)) return disable()
    input.failed?.(error)
  }

  async function toInput(item: ChatQuote): Promise<Quotes.QuoteInput> {
    const images = (item.commentPrompt ?? []).filter((part): part is ImageAttachmentPart => part.type === "image")
    const ids = new Map<string, string>()
    for (const image of images) {
      const id = await attachmentID(image)
      if (id) ids.set(image.blob.id, id)
    }
    const prompt = item.commentPrompt
      ?.filter((part) => part.type !== "image" || ids.has(part.blob.id))
      .map((part) => (part.type === "image" ? { ...part, blob: { id: ids.get(part.blob.id)!, url: "" } } : part))
    return {
      id: item.id,
      messageID: item.messageID,
      partID: item.partID,
      text: item.text,
      comment: item.comment,
      // Optional fields encode as `undefined`, which is not JSON; the round trip drops them.
      ...(prompt ? { commentPrompt: decodeJson(JSON.parse(JSON.stringify(encodePrompt(prompt)))) } : {}),
      ...(item.anchor ? { anchor: item.anchor } : {}),
      attachments: [...new Set(ids.values())],
    }
  }

  // Missing local bytes (a draft whose blob was evicted) drop the image instead of failing the quote.
  async function attachmentID(image: ImageAttachmentPart) {
    const existing = uploaded.get(image.blob.id) ?? (loaded.has(image.blob.id) ? image.blob.id : undefined)
    if (existing) return existing
    const blob = await blobData(image.blob).catch(() => undefined)
    if (!blob) return
    const attachment = await input.api.upload({ mime: image.mime, filename: image.filename, data: await base64(blob) })
    uploaded.set(image.blob.id, attachment.id)
    loaded.set(attachment.id, URL.createObjectURL(blob))
    return attachment.id
  }

  function toView(quote: Quotes.Quote): ChatQuote {
    const decoded = quote.commentPrompt ? Option.getOrUndefined(decodePrompt(quote.commentPrompt)) : undefined
    const referenced = new Set((decoded ?? []).flatMap((part) => (part.type === "image" ? [part.blob.id] : [])))
    const extra = quote.attachments
      .filter((attachment) => attachment.mime.startsWith("image/") && !referenced.has(attachment.id))
      .map(
        (attachment): ImageAttachmentPart => ({
          type: "image",
          id: attachment.id,
          filename: attachment.filename ?? attachment.id.slice(0, 12),
          mime: attachment.mime,
          blob: { id: attachment.id, url: "" },
        }),
      )
    const prompt =
      decoded || extra.length
        ? [
            ...(decoded ?? [{ type: "text" as const, content: quote.comment, start: 0, end: quote.comment.length }]),
            ...extra,
          ].map((part) =>
            part.type === "image" ? { ...part, blob: { id: part.blob.id, url: loaded.get(part.blob.id) ?? "" } } : part,
          )
        : undefined
    return {
      id: quote.id,
      messageID: quote.messageID,
      partID: quote.partID,
      text: quote.text,
      comment: quote.comment,
      ...(prompt ? { commentPrompt: prompt } : {}),
      ...(quote.anchor ? { anchor: { ...quote.anchor } } : {}),
    }
  }

  function apply(next: Quotes.State) {
    if (next.revision < state.revision) return
    const previous = new Map(known)
    known.clear()
    next.quotes.forEach((quote) => known.set(quote.id, quote))
    state.revision = next.revision
    const editing = quotes.editor.current()
    const view = quotes.server.live().flatMap((item) => {
      const server = known.get(item.id)
      if (dirty.has(item.id) || item.id === editing) return [item]
      if (!server) return previous.has(item.id) ? [] : [item]
      return [previous.get(item.id)?.revision === server.revision ? item : toView(server)]
    })
    const added = next.quotes
      .filter((quote) => !view.some((item) => item.id === quote.id))
      .filter((quote) => !removing.has(quote.id) && !sending.has(quote.id) && !clearing.has(quote.id))
      .filter((quote) => !previous.has(quote.id) || previous.get(quote.id)!.revision !== quote.revision)
      .map(toView)
    quotes.server.apply([...view, ...added])
    void load()
  }

  // Server attachments are fetched once and kept as object URLs for the page's lifetime: draft-store
  // URLs are revoked once no persisted draft references them, and server drafts are not persisted.
  async function load() {
    const missing = [
      ...new Set(
        quotes.server
          .live()
          .flatMap((quote) => quote.commentPrompt ?? [])
          .flatMap((part) => (part.type === "image" && !part.blob.url ? [part.blob.id] : [])),
      ),
    ].filter((id) => !loaded.has(id))
    if (!missing.length) return
    await Promise.all(
      missing.map(async (id) => {
        const attachment = await input.api.attachment(id).catch(() => undefined)
        if (!attachment) return
        const bytes = Uint8Array.from(atob(attachment.data), (char) => char.charCodeAt(0))
        loaded.set(id, URL.createObjectURL(new Blob([bytes], { type: attachment.mime })))
      }),
    )
    if (state.mode !== "server") return
    quotes.server.apply(
      quotes.server.live().map((quote) =>
        quote.commentPrompt
          ? {
              ...quote,
              commentPrompt: quote.commentPrompt.map((part) =>
                part.type === "image" && !part.blob.url && loaded.has(part.blob.id)
                  ? { ...part, blob: { id: part.blob.id, url: loaded.get(part.blob.id)! } }
                  : part,
              ),
            }
          : quote,
      ),
    )
  }

  async function start() {
    await input.ready()
    const probe = await input.api.info().then(
      () => "server" as const,
      (error: unknown) => (unsupported(error) ? ("local" as const) : ("unknown" as const)),
    )
    if (state.disposed || probe !== "server") {
      if (probe === "local") disable()
      return
    }
    const migrated = await migrate()
    if (!migrated || state.disposed) return
    state.mode = "server"
    state.revision = -1
    known.clear()
    quotes.server.enable([])
    apply(migrated)
    if (dirty.size || removing.size || clearing.size) schedule(0)
  }

  // Imports local drafts once, keeping their IDs; anything added during the import is imported next round.
  async function migrate(): Promise<Quotes.State | undefined> {
    const local = quotes.server.local()
    if (!local.length) return input.api.list()
    const inputs = await Promise.all(local.map(toInput))
    const first = await input.api.import(inputs).catch((error: unknown) => error)
    const retried =
      isFailure(first) && first.type === "attachment_missing"
        ? (uploaded.clear(),
          await input.api.import(await Promise.all(local.map(toInput))).catch((error: unknown) => error))
        : first
    if (!isImported(retried)) {
      // A full or deleted Session keeps its local drafts; network failures try again on the next refresh.
      if (isFailure(retried) && !unsupported(retried)) state.mode = "local"
      return
    }
    quotes.server.forget(local.map((quote) => quote.id))
    return quotes.server.local().length ? migrate() : retried.state
  }

  function disable() {
    state.mode = "local"
    clearTimeout(state.timer)
    quotes.server.disable()
  }

  async function refresh() {
    if (state.disposed) return
    if (state.mode !== "server") {
      state.starting ??= start()
        .catch((error: unknown) => report(error))
        .finally(() => (state.starting = undefined))
      return state.starting
    }
    await flush()
    const next = await input.api.list().catch((error: unknown) => {
      if (unsupported(error)) disable()
      return undefined
    })
    if (next && state.mode === "server") apply(next)
  }

  function report(error: unknown) {
    if (unsupported(error)) return disable()
    console.warn("[chat-quotes] sync failed", error)
  }

  return {
    refresh,
    flush,
    updated(revision: number) {
      if (state.mode === "server" && revision > state.revision) void refresh()
    },
    mode: () => state.mode,
    dispose() {
      state.disposed = true
      clearTimeout(state.timer)
      disconnect()
    },
  }
}

function same(item: ChatQuote, server: Quotes.Quote) {
  return item.comment === server.comment && JSON.stringify(item.anchor) === JSON.stringify(server.anchor)
}

function unsupported(error: unknown) {
  return isFailure(error) && (error.type === "rpc.unavailable" || error.type === "rpc.method_not_found")
}

function isFailure(error: unknown): error is Failure {
  return typeof error === "object" && error !== null && "type" in error && typeof error.type === "string"
}

function isSaved(value: unknown): value is { revision: number; quote: Quotes.Quote } {
  return typeof value === "object" && value !== null && "quote" in value
}

function isImported(value: unknown): value is { state: Quotes.State } {
  return typeof value === "object" && value !== null && "state" in value
}

function readIds(data: unknown) {
  if (typeof data !== "object" || data === null || !("ids" in data) || !Array.isArray(data.ids)) return []
  return data.ids.filter((id): id is string => typeof id === "string")
}

/** Binds a Session composer to `custom.quotes` of its server for the lifetime of the current owner. */
export function connectChatQuotes(
  state: Pick<ComposerState, "quotes" | "ready">,
  sdk: Pick<ServerSDK, "api" | "connection" | "event">,
  scope: { dir: string; id: string },
) {
  const language = useLanguage()
  const options = { location: { directory: base64Decode(scope.dir) } }
  const sessionID = scope.id
  const client = () => sdk.api.rpc(Quotes.Definition)
  const sync = createChatQuoteSync({
    quotes: state.quotes,
    ready: () => state.ready.promise,
    api: {
      info: () => client().info({}, options),
      list: () => client().list({ sessionID }, options),
      save: (quote) => client().save({ sessionID, quote }, options),
      remove: (id) => client().remove({ sessionID, id }, options),
      clear: (ids) => client().clear({ sessionID, ids, reason: "sent" }, options),
      import: (quotes) => client().import({ sessionID, quotes }, options),
      upload: (input) => client().upload({ sessionID, ...input }, options),
      attachment: (id) => client().attachment({ sessionID, id }, options),
    },
    failed: () => showToast({ title: language.t("chatQuotes.syncFailed") }),
  })
  createEffect(
    on(
      () => (sdk.connection.status() === "connected" ? sdk.connection.epoch() : undefined),
      (epoch) => epoch !== undefined && void sync.refresh(),
    ),
  )
  // The app's event source survives reconnects; an RPC client subscription ends with the stream it opened.
  onCleanup(
    sdk.event.on("rpc.custom.quotes.updated", (event) => {
      const data = decodeUpdated(event.data)
      if (Option.isSome(data) && data.value.sessionID === sessionID) sync.updated(data.value.revision)
    }),
  )
  const visible = () => (document.visibilityState === "visible" ? void sync.refresh() : void sync.flush())
  const hidden = () => void sync.flush()
  window.addEventListener("focus", visible)
  document.addEventListener("visibilitychange", visible)
  window.addEventListener("pagehide", hidden)
  onCleanup(() => {
    window.removeEventListener("focus", visible)
    document.removeEventListener("visibilitychange", visible)
    window.removeEventListener("pagehide", hidden)
    sync.dispose()
  })
  return sync
}

async function base64(blob: Blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer())
  const chunks: string[] = []
  for (let index = 0; index < bytes.length; index += 0x8000)
    chunks.push(String.fromCharCode(...bytes.subarray(index, index + 0x8000)))
  return btoa(chunks.join(""))
}
