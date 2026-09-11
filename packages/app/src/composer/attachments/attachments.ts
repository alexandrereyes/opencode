import { onCleanup, onMount } from "solid-js"
import { makeEventListener } from "@solid-primitives/event-listener"
import { createBlobReference } from "@/runtime/persistence/drafts"
import { uuid } from "@/runtime/persistence/uuid"
import type { ComposerAttachment, ComposerPrompt } from "../types"
import { getCursorPosition } from "../editor/dom"

const accepted = [
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "application/pdf",
  "text/*",
  "application/json",
  "application/ld+json",
  "application/toml",
  "application/x-toml",
  "application/x-yaml",
  "application/xml",
  "application/yaml",
  ".c",
  ".cc",
  ".cjs",
  ".conf",
  ".cpp",
  ".css",
  ".csv",
  ".cts",
  ".env",
  ".go",
  ".gql",
  ".graphql",
  ".h",
  ".hh",
  ".hpp",
  ".htm",
  ".html",
  ".ini",
  ".java",
  ".js",
  ".json",
  ".jsx",
  ".log",
  ".md",
  ".mdx",
  ".mjs",
  ".mts",
  ".py",
  ".rb",
  ".rs",
  ".sass",
  ".scss",
  ".sh",
  ".sql",
  ".toml",
  ".ts",
  ".tsx",
  ".txt",
  ".xml",
  ".yaml",
  ".yml",
  ".zsh",
]

type PromptTarget = {
  current: () => ComposerPrompt
  cursor: () => number | undefined
  set: (prompt: ComposerPrompt, cursor?: number) => void
  replace: (prompt: ComposerPrompt, range: { start: number; end: number }, order?: number) => void
  selection: () => { start: number; end: number }
  trackSelection?: () =>
    | { current: () => { start: number; end: number }; order: number; release: () => void }
    | undefined
}

export type ComposerAttachmentConfig = {
  picker?: (
    options: { defaultPath?: string; multiple?: boolean; accept?: string[] },
    onFile: (file: File) => Promise<unknown>,
  ) => Promise<void>
  directory: () => string
  isDialogActive: () => boolean
  warn: () => void
  duplicate: () => void
  onError: (error: unknown) => void
  readClipboardImage?: () => Promise<File | null>
  getPathForFile?: (file: File) => string
  onDragCancel?: (callback: () => void) => () => void
  store?: (file: File) => Promise<{ id: string; url: string }>
}

export function createComposerAttachments(
  input: ComposerAttachmentConfig & {
    capture: () => PromptTarget
    editor: () => HTMLElement | undefined
    focusEditor: () => void
    addPart: (part: ComposerPrompt[number]) => boolean
    setDraggingType: (type: "image" | "@mention" | null) => void
  },
) {
  const pendingFilenames = new Set<string>()
  const clearDrag = () => {
    input.setDraggingType(null)
  }
  const capture = (trackSelection = false) => {
    const prompt = input.capture()
    const editor = input.editor()
    if (!editor) return undefined
    const tracked = trackSelection ? prompt.trackSelection?.() : undefined
    return {
      prompt,
      cursor: prompt.cursor() ?? getCursorPosition(editor),
      selection: tracked?.current ?? prompt.selection,
      release: tracked?.release,
      replace: (content: ComposerPrompt, range: { start: number; end: number }) =>
        prompt.replace(content, range, tracked?.order),
    }
  }
  const prepare = async (
    file: File,
    target: NonNullable<ReturnType<typeof capture>>,
    clipboard = false,
    filename = file.name,
    pending: ComposerAttachment[] = [],
  ) => {
    const mime = await attachmentMime(file)
    if (!mime) return undefined
    const blob = input.store ? await input.store(file) : await createBlobReference(file)
    const sourcePath = input.getPathForFile?.(file) || undefined
    const duplicate = [...target.prompt.current(), ...pending].some(
      (part) =>
        part.type === "image" &&
        part.blob.id === blob.id &&
        (sourcePath ? part.sourcePath === sourcePath : !part.sourcePath && (clipboard || part.filename === filename)),
    )
    if (duplicate) {
      input.duplicate()
      return false
    }
    return {
      type: "image" as const,
      id: uuid(),
      filename,
      sourcePath,
      mime,
      blob,
    }
  }
  const add = async (file: File, toast = true, target = capture(), clipboard = false) => {
    if (!target) return false
    const attachment = await prepare(file, target, clipboard)
    if (attachment === undefined) {
      if (toast) input.warn()
      return false
    }
    if (attachment === false) return true
    target.prompt.set([...target.prompt.current(), attachment], target.cursor)
    return true
  }
  const addAttachments = async (files: File[], toast = true, target = capture()) => {
    return files
      .reduce(async (result, file) => {
        const previous = await result
        return (await add(file, false, target)) || previous
      }, Promise.resolve(false))
      .then((found) => {
        if (!found && files.length > 0 && toast) input.warn()
        return found
      })
  }
  const addCitedAttachments = async (
    files: File[],
    pastedText: string,
    target: NonNullable<ReturnType<typeof capture>>,
  ) => {
    const names = assignAttachmentFilenames(files, [
      ...target.prompt
        .current()
        .filter((part): part is ComposerAttachment => part.type === "image")
        .map((part) => part.filename),
      ...pendingFilenames,
    ])
    names.forEach((name) => pendingFilenames.add(name.toLowerCase()))
    return files
      .reduce(
        async (result, file, index) => {
          const state = await result
          const attachment = await prepare(file, target, true, names[index], state.attachments)
          if (attachment === false) return { ...state, handled: true }
          if (!attachment) return state
          return { attachments: [...state.attachments, attachment], handled: true }
        },
        Promise.resolve({ attachments: [] as ComposerAttachment[], handled: false }),
      )
      .then((result) => {
        const selection = target.selection()
        if (result.attachments.length === 0) {
          if (pastedText) {
            target.replace([{ type: "text", content: pastedText, start: 0, end: pastedText.length }], selection)
          }
          if (!result.handled) input.warn()
          return result.handled || !!pastedText
        }
        const citations = result.attachments.map((attachment) => `[${attachment.filename}]`).join(" ")
        const insertion = withInsertionBoundaries(
          `${pastedText}${pastedText && !/\s$/.test(pastedText) ? " " : ""}${citations}`,
          promptText(target.prompt.current()).slice(0, selection.start),
          promptText(target.prompt.current()).slice(selection.end),
        )
        const citationStart = insertion.indexOf(citations, pastedText.length)
        const cited = result.attachments.map((attachment, index) => {
          const text = `[${attachment.filename}]`
          const start =
            citationStart +
            result.attachments.slice(0, index).reduce((length, item) => length + item.filename.length + 2, 0) +
            index
          return { ...attachment, mention: { text, start, end: start + text.length } }
        })
        target.replace([{ type: "text", content: insertion, start: 0, end: insertion.length }, ...cited], selection)
        return true
      })
      .finally(() => names.forEach((name) => pendingFilenames.delete(name.toLowerCase())))
  }
  const addUncitedClipboardAttachments = async (
    files: File[],
    pastedText: string,
    target: NonNullable<ReturnType<typeof capture>>,
  ) => {
    const result = await files.reduce(
      async (pending, file) => {
        const state = await pending
        const attachment = await prepare(file, target, true, file.name, state.attachments)
        if (attachment === false) return { ...state, handled: true }
        if (!attachment) return state
        return { attachments: [...state.attachments, attachment], handled: true }
      },
      Promise.resolve({ attachments: [] as ComposerAttachment[], handled: false }),
    )
    if (result.attachments.length > 0) {
      target.prompt.set([...target.prompt.current(), ...result.attachments], target.selection().end)
      return true
    }
    if (pastedText) {
      target.replace([{ type: "text", content: pastedText, start: 0, end: pastedText.length }], target.selection())
    }
    if (!result.handled) input.warn()
    return result.handled || !!pastedText
  }
  const handlePaste = async (event: ClipboardEvent) => {
    const clipboardData = event.clipboardData
    if (!clipboardData) return
    const target = capture(true)
    if (!target) return
    event.preventDefault()
    event.stopPropagation()
    const files = Array.from(clipboardData.items).flatMap((item) => {
      if (item.kind !== "file") return []
      const file = item.getAsFile()
      return file ? [file] : []
    })
    if (files.length > 0) {
      const pastedText = clipboardData.getData("text/plain").replace(/\r\n?/g, "\n")
      if (files.some((file) => !isImageFile(file))) {
        await addUncitedClipboardAttachments(files, pastedText, target).finally(() => target.release?.())
        return
      }
      await addCitedAttachments(files, pastedText, target).finally(() => target.release?.())
      return
    }
    const plainText = clipboardData.getData("text/plain") ?? ""
    if (input.readClipboardImage && !plainText) {
      await input
        .readClipboardImage()
        .then((file) => (file ? addCitedAttachments([file], "", target) : false))
        .finally(() => target.release?.())
      return
    }
    target.release?.()
    if (!plainText) return
    const text = plainText.includes("\r") ? plainText.replace(/\r\n?/g, "\n") : plainText
    const put = () => {
      if (input.addPart({ type: "text", content: text, start: 0, end: 0 })) return true
      input.focusEditor()
      return input.addPart({ type: "text", content: text, start: 0, end: 0 })
    }
    put()
  }
  const handleDrop = async (event: DragEvent) => {
    if (input.isDialogActive()) return
    event.preventDefault()
    clearDrag()
    const plainText = event.dataTransfer?.getData("text/plain")
    if (plainText?.startsWith("file:")) {
      const path = plainText.slice("file:".length)
      input.focusEditor()
      input.addPart({ type: "file", path, content: `@${path}`, start: 0, end: 0 })
      return
    }
    const files = event.dataTransfer?.files
    if (files) await addAttachments(Array.from(files))
  }

  onMount(() => {
    const cancel = input.onDragCancel?.(clearDrag)
    if (cancel) onCleanup(cancel)
    makeEventListener(document, "dragover", (event) => {
      if (input.isDialogActive()) return
      event.preventDefault()
      if (event.dataTransfer?.types.includes("Files")) input.setDraggingType("image")
      else if (event.dataTransfer?.types.includes("text/plain")) input.setDraggingType("@mention")
    })
    makeEventListener(document, "dragleave", (event) => {
      if (!input.isDialogActive() && !event.relatedTarget) clearDrag()
    })
    makeEventListener(document, "keydown", (event) => {
      if (event.key === "Escape") clearDrag()
    })
    makeEventListener(document, "drop", handleDrop)
  })

  return {
    addAttachments,
    handlePaste,
    handleDrop,
    pick(fallback: () => void) {
      if (!input.picker) {
        fallback()
        return
      }
      void input
        .picker({ defaultPath: input.directory(), multiple: true, accept: accepted }, (file) => add(file))
        .catch(input.onError)
    },
  }
}

function isImageFile(file: File) {
  if (file.type.toLowerCase().startsWith("image/")) return true
  return imageExtensions.has(file.name.split(".").at(-1)?.toLowerCase() ?? "")
}

const genericImageNames =
  /^(?:image|screenshot|screen[-_ ]?shot|clipboard|pasted[-_ ]?image|untitled|unknown|file|blob)(?:[-_ ]?\(?\d+\)?)?$/i

export function assignAttachmentFilenames(files: readonly File[], existing: readonly string[]) {
  const used = new Set(existing.map((name) => name.toLowerCase()))
  return files.map((file) => {
    const clean =
      file.name
        .replace(/\\/g, "/")
        .split("/")
        .at(-1)
        ?.replace(/[<>:"/\\|?*[\]\u0000-\u001f]/g, "-")
        .trim() || "image"
    const dot = clean.lastIndexOf(".")
    const extension = dot > 0 ? clean.slice(dot + 1).toLowerCase() : imageExtension(file.type)
    const base = dot > 0 ? clean.slice(0, dot) : clean
    const generated = genericImageNames.test(base)
    const root = generated ? "image" : base
    let index = generated ? 1 : 0
    let candidate = `${root}${index ? `-${index}` : ""}.${extension}`
    while (used.has(candidate.toLowerCase())) {
      index = index === 0 ? 2 : index + 1
      candidate = `${root}-${index}.${extension}`
    }
    used.add(candidate.toLowerCase())
    return candidate
  })
}

function imageExtension(mime: string) {
  if (mime === "image/jpeg") return "jpg"
  if (mime === "image/gif") return "gif"
  if (mime === "image/webp") return "webp"
  return "png"
}

function promptText(prompt: ComposerPrompt) {
  return prompt.map((part) => ("content" in part ? part.content : "")).join("")
}

function withInsertionBoundaries(content: string, before: string, after: string) {
  const leading = before && !/\s$/.test(before) && !/^\s/.test(content) && !/[([{]$/.test(before) ? " " : ""
  const trailing = after && !/\s$/.test(content) && !/^\s/.test(after) && !/^[\])}.,;:!?]/.test(after) ? " " : ""
  return `${leading}${content}${trailing}`
}

const imageMimes = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"])

const imageExtensions = new Map([
  ["gif", "image/gif"],
  ["jpeg", "image/jpeg"],
  ["jpg", "image/jpeg"],
  ["png", "image/png"],
  ["webp", "image/webp"],
])
const textMimes = new Set([
  "application/json",
  "application/ld+json",
  "application/toml",
  "application/x-toml",
  "application/x-yaml",
  "application/xml",
  "application/yaml",
])

async function attachmentMime(file: File) {
  const type = file.type.split(";", 1)[0]?.trim().toLowerCase() ?? ""
  if (imageMimes.has(type) || type === "application/pdf") return type
  const index = file.name.lastIndexOf(".")
  const suffix = index === -1 ? "" : file.name.slice(index + 1).toLowerCase()
  const fallback = imageExtensions.get(suffix) ?? (suffix === "pdf" ? "application/pdf" : undefined)
  if ((!type || type === "application/octet-stream") && fallback) return fallback
  if (type.startsWith("text/") || textMimes.has(type) || type.endsWith("+json") || type.endsWith("+xml")) {
    return "text/plain"
  }
  const bytes = new Uint8Array(await file.slice(0, 4096).arrayBuffer())
  if (bytes.some((byte) => byte === 0)) return
  const control = bytes.filter((byte) => byte < 9 || (byte > 13 && byte < 32)).length
  if (bytes.length > 0 && control / bytes.length > 0.3) return
  return "text/plain"
}
