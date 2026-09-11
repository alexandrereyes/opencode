import { batch, untrack, type Accessor } from "solid-js"
import type { SetStoreFunction, Store } from "solid-js/store"
import type {
  ComposerAgentPart,
  ComposerAppPart,
  ComposerFilePart,
  ComposerSkillPart,
  ComposerSnippetPart,
  ComposerPersistedState,
  ComposerPrompt,
  ComposerSessionPart,
} from "../types"
import { normalizeComposerCursor, normalizeComposerPrompt, normalizeComposerText, promptLength } from "../prompt-parts"

export type ComposerStateStore = [
  Store<ComposerPersistedState> | Accessor<Store<ComposerPersistedState>>,
  SetStoreFunction<ComposerPersistedState>,
]

export type ComposerStateStoreInput = ComposerStateStore | Accessor<ComposerStateStore>

export function createComposerEditorActions(input: ComposerStateStoreInput) {
  const tuple = () => (typeof input === "function" ? input() : input)
  const store = () => {
    const value = tuple()[0]
    return typeof value === "function" ? value() : value
  }
  const setStore = () => tuple()[1]
  const clearRetry = () => {
    if (untrack(() => store().retry) !== undefined) setStore()("retry", undefined)
  }

  return {
    get state() {
      return store()
    },
    setPrompt(prompt: ComposerPrompt, cursor?: number) {
      const next = normalizeComposerPrompt(prompt)
      // Persisted setters encode on every call, even inside a reactive batch.
      batch(() =>
        setStore()({
          prompt: next,
          ...(cursor !== undefined ? { cursor: normalizeComposerCursor(prompt, cursor) } : {}),
          retry: undefined,
        }),
      )
    },
    setCursor(cursor: number) {
      if (untrack(() => store().cursor) === cursor) return
      setStore()("cursor", cursor)
    },
    setMode(mode: "normal" | "shell") {
      if (untrack(() => store().mode === mode && store().retry === undefined)) return
      setStore()({ mode, retry: undefined })
    },
    setText(content: string) {
      const value = normalizeComposerText(content)
      batch(() =>
        setStore()((state) => ({
          prompt: [
            { type: "text", content: value, start: 0, end: value.length },
            ...state.prompt.filter((part) => part.type === "image"),
          ],
          cursor: value.length,
          retry: undefined,
        })),
      )
    },
    addText(content: string, cursor = store().cursor ?? promptLength(store().prompt)) {
      const value = normalizeComposerText(content)
      batch(() =>
        setStore()((state) => {
          const position = normalizeComposerCursor(state.prompt, cursor)
          return {
            prompt: insertText(normalizeComposerPrompt(state.prompt), position, value),
            cursor: position + value.length,
            retry: undefined,
          }
        }),
      )
    },
    replaceRange(content: ComposerPrompt, range: { start: number; end: number }) {
      const prompt = store().prompt
      const start = normalizeComposerCursor(prompt, Math.min(range.start, range.end))
      const end = normalizeComposerCursor(prompt, Math.max(range.start, range.end))
      const replacement = normalizeComposerPrompt(content)
      setStore()({
        prompt: replacePromptRange(normalizeComposerPrompt(prompt), start, end, replacement),
        cursor: start + promptLength(replacement),
        retry: undefined,
      })
    },
    removeContext(key: string) {
      setStore()("context", "items", (items) => items.filter((item) => item.key !== key))
      clearRetry()
    },
    addMention(
      mention:
        | ComposerFilePart
        | ComposerAgentPart
        | ComposerSkillPart
        | ComposerAppPart
        | ComposerSessionPart
        | ComposerSnippetPart,
      range?: { start: number; end: number },
    ) {
      const prompt = normalizeComposerPrompt(store().prompt)
      const text = prompt.map((part) => ("content" in part ? part.content : "")).join("")
      const end = range
        ? normalizeComposerCursor(store().prompt, range.end)
        : normalizeComposerCursor(store().prompt, store().cursor ?? promptLength(store().prompt))
      const trigger = mention.type === "snippet" ? "#" : mention.type === "skill" ? "$" : "@"
      const start = range
        ? normalizeComposerCursor(store().prompt, range.start)
        : text.slice(0, end).lastIndexOf(trigger)
      setStore()({
        prompt: insertMention(prompt, start < 0 ? end : start, end, mention),
        cursor: (start < 0 ? end : start) + mention.content.length + 1,
        retry: undefined,
      })
    },
    removeAttachment(id: string) {
      setStore()("prompt", (parts) => parts.filter((part) => part.type !== "image" || part.id !== id))
      clearRetry()
    },
  }
}

function insertText(prompt: ComposerPrompt, cursor: number, content: string): ComposerPrompt {
  return replacePromptRange(prompt, cursor, cursor, [{ type: "text", content, start: 0, end: content.length }])
}

function replacePromptRange(
  prompt: ComposerPrompt,
  start: number,
  end: number,
  content: ComposerPrompt,
): ComposerPrompt {
  const before: ComposerPrompt = []
  const after: ComposerPrompt = []
  const images = prompt.filter((part) => part.type === "image")
  let position = 0
  prompt.forEach((part) => {
    if (part.type === "image") return
    const partStart = position
    position += part.content.length
    if (position <= start) {
      before.push(part)
      return
    }
    if (partStart >= end) {
      after.push(part)
      return
    }
    const prefix = part.content.slice(0, Math.max(0, start - partStart))
    const suffix = part.content.slice(Math.max(0, end - partStart))
    if (prefix) before.push({ type: "text", content: prefix, start: 0, end: 0 })
    if (suffix) after.push({ type: "text", content: suffix, start: 0, end: 0 })
  })
  return withOffsets([...before, ...content, ...after, ...images])
}

function insertMention(
  prompt: ComposerPrompt,
  start: number,
  end: number,
  mention:
    | ComposerFilePart
    | ComposerAgentPart
    | ComposerSkillPart
    | ComposerAppPart
    | ComposerSessionPart
    | ComposerSnippetPart,
): ComposerPrompt {
  return replacePromptRange(prompt, start, end, [mention, { type: "text", content: " ", start: 0, end: 0 }])
}

function withOffsets(prompt: ComposerPrompt): ComposerPrompt {
  let offset = 0
  return prompt
    .reduce<ComposerPrompt>((result, part) => {
      const previous = result.at(-1)
      if (part.type === "text" && previous?.type === "text") {
        result[result.length - 1] = { ...previous, content: previous.content + part.content }
        return result
      }
      result.push(part)
      return result
    }, [])
    .map((part) => {
      if (part.type === "image") return part
      const next = { ...part, start: offset, end: offset + part.content.length }
      offset = next.end
      return next
    })
}
