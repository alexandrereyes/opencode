import { batch, untrack, type Accessor } from "solid-js"
import { createStore, reconcile, type SetStoreFunction } from "solid-js/store"
import { Persist, persisted } from "@/runtime/persistence/storage"
import { ServerScope } from "@/runtime/server/scope"
import type { Platform } from "@/runtime/platform/platform"
import { clonePrompt } from "./prompt-parts"
import { uuid } from "@/runtime/persistence/uuid"
import type { ChatQuote } from "./schema"
import {
  ComposerStore,
  DEFAULT_PROMPT,
  contextItemKey,
  type ContextItem,
  type FileContextItem,
  type Prompt,
  type PromptModel,
} from "./schema"

export { DEFAULT_PROMPT } from "./schema"
export type {
  AppPart,
  AgentPart,
  ComposerStore,
  ContentPart,
  ContextItem,
  FileAttachmentPart,
  FileContextItem,
  ImageAttachmentPart,
  PathAttachmentPart,
  Prompt,
  PromptModel,
  SessionPart,
  SkillPart,
  SnippetPart,
  TextPart,
} from "./schema"

export type PromptScope = { draftID: string } | { dir: string; id?: string }

type InitialPrompt = {
  prompt?: string
  model?: PromptModel
}

export function isCommentItem(item: ContextItem | (ContextItem & { key: string })) {
  return item.type === "file" && !!item.comment?.trim()
}

function createComposerActions(setStore: SetStoreFunction<ComposerStore>) {
  return {
    set(prompt: Prompt, cursorPosition?: number) {
      batch(() =>
        setStore({
          prompt: clonePrompt(prompt),
          ...(cursorPosition !== undefined ? { cursor: cursorPosition } : {}),
          retry: undefined,
        }),
      )
    },
    reset() {
      batch(() => setStore({ prompt: clonePrompt(DEFAULT_PROMPT), cursor: 0, retry: undefined }))
    },
  }
}

function composerTarget(serverScope: ServerScope, scope: PromptScope) {
  return "draftID" in scope
    ? Persist.prompt(Persist.draft(scope.draftID, "prompt"))
    : Persist.prompt({
        ...Persist.serverScoped(serverScope, scope.dir, scope.id, "prompt"),
        ...(serverScope === ServerScope.local
          ? { previousKey: `${scope.dir}/prompt${scope.id ? "/" + scope.id : ""}.v2` }
          : {}),
      })
}

function initialComposerStore(initial?: InitialPrompt): ComposerStore {
  const text = initial?.prompt
  return {
    prompt:
      text === undefined ? clonePrompt(DEFAULT_PROMPT) : [{ type: "text", content: text, start: 0, end: text.length }],
    cursor: text === undefined ? undefined : text.length,
    model: initial?.model ? { ...initial.model } : undefined,
    context: {
      items: [],
    },
  }
}

export type ChatQuoteSync = {
  changed(id: string): void
  removed(id: string): void
  replaced(before: ChatQuote[], after: ChatQuote[]): void
  sending(ids: string[]): void
  sent(ids: string[]): void
  flush(): void
}

export type RevertProgress =
  | { phase: "planning" | "session" | "inbox" }
  | { phase: "descendants"; completed: number; total: number }

function cloneQuotes(items: readonly ChatQuote[]): ChatQuote[] {
  return items.map((item) => ({
    ...item,
    ...(item.commentPrompt
      ? {
          commentPrompt: clonePrompt(item.commentPrompt).map((part) =>
            part.type === "image" ? { ...part, blob: { ...part.blob } } : part,
          ),
        }
      : {}),
    ...(item.anchor ? { anchor: { ...item.anchor } } : {}),
  }))
}

function createComposerStateValue(store: ComposerStore, setStore: SetStoreFunction<ComposerStore>) {
  // Selection/editor geometry is transient; only the text anchor belongs in the draft.
  const [quoteEditor, setQuoteEditor] = createStore<{
    id: string
    position?: { left: number; top: number; bottom: number }
    uploading: boolean
  }>({ id: "", uploading: false })
  // Drafts mirrored from `custom.quotes`; they replace the persisted `store.quotes` while the server stores them.
  const [remote, setRemote] = createStore<{ sync: boolean; live: ChatQuote[]; preview?: ChatQuote[] }>({
    sync: false,
    live: [],
  })
  let sync: ChatQuoteSync | undefined
  const actions = createComposerActions(setStore)
  const settled = Promise.resolve(true)
  let pendingRevert: Promise<boolean> | undefined
  const [revertState, setRevertState] = createStore({
    boundary: undefined as string | undefined,
    local: false,
    pending: false,
    progress: undefined as RevertProgress | undefined,
  })
  const revertProject = new Set<() => void>()
  const revert = {
    pending: () => revertState.pending,
    progress: () => revertState.progress,
    report: (progress: RevertProgress) => setRevertState({ progress }),
    scheduled: (boundary: string | undefined) =>
      pendingRevert && revertState.boundary === boundary ? pendingRevert : undefined,
    boundary: (current: string | undefined, available: (messageID: string) => boolean = () => true) => {
      const server = current && available(current) ? current : undefined
      if (!revertState.local) return server
      if (revertState.boundary && !available(revertState.boundary)) {
        setRevertState("local", false)
        return server
      }
      if (!revertState.pending && current === revertState.boundary) setRevertState("local", false)
      return revertState.boundary
    },
    schedule(boundary: string | undefined, action: () => Promise<boolean>) {
      if (pendingRevert && revertState.boundary === boundary) return pendingRevert
      if (!pendingRevert) setRevertState("progress", { phase: "planning" })
      setRevertState({ boundary, local: true, pending: true })
      const operation = (pendingRevert ?? settled).then((ready) => (ready ? action() : false))
      const tracked = operation.then(
        (result) => {
          if (pendingRevert === tracked) {
            pendingRevert = undefined
            setRevertState({ pending: false, progress: undefined, ...(!result ? { local: false } : {}) })
          }
          return result
        },
        (error) => {
          if (pendingRevert === tracked) {
            pendingRevert = undefined
            setRevertState({ pending: false, progress: undefined, local: false })
          }
          throw error
        },
      )
      pendingRevert = tracked
      return tracked
    },
    async wait() {
      while (pendingRevert) {
        const operation = pendingRevert
        if (!(await operation)) return false
      }
      return true
    },
    prepare() {
      revertProject.forEach((action) => action())
    },
    onProject(action: () => void) {
      revertProject.add(action)
      return () => {
        revertProject.delete(action)
      }
    },
  }
  const clearRetry = () => {
    if (untrack(() => store.retry) !== undefined) setStore("retry", undefined)
  }
  const value = {
    store: [() => store, setStore] as [Accessor<ComposerStore>, SetStoreFunction<ComposerStore>],
    current: () => store.prompt,
    cursor: () => store.cursor,
    model: {
      current: () => store.model,
      set: (model: PromptModel | undefined) => {
        setStore("model", model)
        clearRetry()
      },
    },
    mode: {
      current: () => store.mode ?? "normal",
      set: (mode: "normal" | "shell") => {
        if (untrack(() => store.mode === mode && store.retry === undefined)) return
        setStore({ mode, retry: undefined })
      },
    },
    retry: {
      current: () => store.retry,
      set: (retry: NonNullable<ComposerStore["retry"]>) => setStore("retry", retry),
    },
    quotes: {
      all: () => (remote.sync ? (remote.preview ?? remote.live) : (store.quotes ?? [])),
      editor: {
        current: () => quoteEditor.id,
        position: () => quoteEditor.position,
        open: (id: string) => setQuoteEditor({ id, position: undefined }),
        close: () => setQuoteEditor({ id: "", position: undefined }),
        place: (position: typeof quoteEditor.position) => setQuoteEditor("position", position),
        // An attachment still uploading in the open quote editor would be lost if it closed or the draft were sent.
        uploading: () => quoteEditor.uploading,
        setUploading: (uploading: boolean) => setQuoteEditor("uploading", uploading),
      },
      // A new quote opens its comment editor; quotes arriving from another client do not.
      add(input: Omit<ChatQuote, "id" | "comment">) {
        const quote = { ...input, id: uuid(), comment: "" }
        clearRetry()
        batch(() => {
          if (!remote.sync) setStore("quotes", (items) => [...(items ?? []), quote])
          else if (remote.preview) setRemote("preview", (items) => [...(items ?? []), quote])
          else setRemote("live", (items) => [...items, quote])
          setQuoteEditor({ id: quote.id, position: undefined })
        })
        if (remote.sync && !remote.preview) sync?.changed(quote.id)
        return quote.id
      },
      update(id: string, comment: string, commentPrompt?: Prompt) {
        clearRetry()
        if (!remote.sync) {
          if (!store.quotes) return
          setStore("quotes", (item) => item.id === id, { comment, commentPrompt })
          return
        }
        if (remote.preview) {
          setRemote("preview", (item) => item.id === id, { comment, commentPrompt })
          return
        }
        setRemote("live", (item) => item.id === id, { comment, commentPrompt })
        sync?.changed(id)
      },
      remove(id: string) {
        clearRetry()
        if (!remote.sync) {
          setStore("quotes", (items) => (items ?? []).filter((item) => item.id !== id))
          return
        }
        if (remote.preview) {
          setRemote("preview", (items) => (items ?? []).filter((item) => item.id !== id))
          return
        }
        setRemote("live", (items) => items.filter((item) => item.id !== id))
        sync?.removed(id)
      },
      replace(items: ChatQuote[]) {
        clearRetry()
        if (!remote.sync) {
          setStore(
            "quotes",
            items.map((item) => ({ ...item })),
          )
          return
        }
        const before = untrack(() => remote.live.map((item) => ({ ...item })))
        setRemote("preview", undefined)
        setRemote("live", reconcile(cloneQuotes(items), { key: "id" }))
        sync?.replaced(before, items)
      },
      /**
       * Shows quotes that are not the session's drafts (a history entry, a queued prompt being edited)
       * without publishing them; `live` returns to the drafts. Local drafts have no separate view.
       */
      preview(items: ChatQuote[], live: boolean) {
        if (!remote.sync) return value.quotes.replace(items)
        clearRetry()
        setRemote("preview", live ? undefined : cloneQuotes(items))
      },
      /** The quotes left in a prompt being sent; they stay on the server until `sent`. */
      sending(ids: string[]) {
        clearRetry()
        if (!remote.sync) {
          setStore("quotes", (items) => (items ?? []).filter((item) => !ids.includes(item.id)))
          return
        }
        setRemote({ preview: undefined, live: remote.live.filter((item) => !ids.includes(item.id)) })
        sync?.sending(ids)
      },
      /** The server admitted the prompt carrying these quotes. */
      sent(ids: string[]) {
        if (remote.sync) sync?.sent(ids)
      },
      flush() {
        if (remote.sync) sync?.flush()
      },
      server: {
        active: () => remote.sync,
        connect(hooks: ChatQuoteSync) {
          sync = hooks
          return () => {
            if (sync === hooks) sync = undefined
          }
        },
        enable(items: ChatQuote[]) {
          setRemote({ sync: true, preview: undefined })
          setRemote("live", reconcile(cloneQuotes(items), { key: "id" }))
        },
        disable() {
          setRemote({ sync: false, preview: undefined, live: [] })
        },
        live: () => remote.live,
        apply(items: ChatQuote[]) {
          setRemote("live", reconcile(cloneQuotes(items), { key: "id" }))
        },
        /** Local drafts written before the server stored them, for the one-time import. */
        local: () => store.quotes ?? [],
        forget(ids: string[]) {
          setStore("quotes", (items) => (items ?? []).filter((item) => !ids.includes(item.id)))
        },
      },
    },
    context: {
      items: () => store.context.items,
      add(item: ContextItem) {
        const key = contextItemKey(item)
        if (store.context.items.find((x) => x.key === key)) return
        setStore("context", "items", (items) => [...items, { key, ...item }])
        clearRetry()
      },
      remove(key: string) {
        setStore("context", "items", (items) => items.filter((x) => x.key !== key))
        clearRetry()
      },
      removeComment(path: string, commentID: string) {
        setStore("context", "items", (items) =>
          items.filter((item) => !(item.type === "file" && item.path === path && item.commentID === commentID)),
        )
        clearRetry()
      },
      updateComment(path: string, commentID: string, next: Partial<FileContextItem> & { comment?: string }) {
        setStore("context", "items", (items) =>
          items.map((item) => {
            if (item.type !== "file" || item.path !== path || item.commentID !== commentID) return item
            const value = { ...item, ...next }
            return { ...value, key: contextItemKey(value) }
          }),
        )
        clearRetry()
      },
      /** Replaces every item, as restoring a sent prompt replaces the whole draft. */
      replace(items: FileContextItem[]) {
        setStore(
          "context",
          "items",
          [...new Map(items.map((item) => [contextItemKey(item), item] as const)).entries()].map(([key, item]) => ({
            ...item,
            key,
          })),
        )
        clearRetry()
      },
      replaceComments(items: FileContextItem[]) {
        setStore("context", "items", (current) => [
          ...current.filter((item) => !isCommentItem(item)),
          ...items.map((item) => ({ ...item, key: contextItemKey(item) })),
        ])
        clearRetry()
      },
    },
    set: (prompt: Prompt, cursorPosition?: number) => actions.set(prompt, cursorPosition),
    reset: () => actions.reset(),
    revert,
    capture: () => value,
  }
  return value
}

function createPersistedComposer(
  target: ReturnType<typeof composerTarget>,
  initial?: InitialPrompt,
  platform?: Platform,
) {
  const [store, setStore, _, ready] = persisted(target, ComposerStore, initialComposerStore(initial), platform)
  return { ready, ...createComposerStateValue(store, setStore) }
}

export function createComposerState(
  serverScope: ServerScope,
  scope: PromptScope,
  initial?: InitialPrompt,
  platform?: Platform,
) {
  return createPersistedComposer(composerTarget(serverScope, scope), initial, platform)
}

export function createDraftComposerState(draftID: string, initial?: InitialPrompt) {
  return createPersistedComposer(Persist.prompt(Persist.draft(draftID, "prompt")), initial)
}

export type ComposerState = ReturnType<typeof createComposerState>

export function createComposerReady(session: Accessor<ComposerState>) {
  return Object.defineProperty(() => session().ready(), "promise", {
    get: () => session().ready.promise,
  }) as (() => boolean) & { readonly promise: Promise<unknown> | undefined }
}

export function createMemoryComposerState(initial?: InitialPrompt) {
  const [store, setStore] = createStore<ComposerStore>(initialComposerStore(initial))
  const ready = Object.assign(() => true, { promise: Promise.resolve(true) })
  return {
    ready,
    ...createComposerStateValue(store, setStore),
  }
}
