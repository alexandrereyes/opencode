import { onCleanup, untrack, type ParentProps } from "solid-js"
import { createStore } from "solid-js/store"
import { createSimpleContext } from "@opencode/ui-custom/context"
import { MarkdownProvider, useMarkdown } from "@opencode/session-ui-custom/context/markdown"
import { useFile } from "@/workspaces/files/model"
import { artifactKind, resolveArtifactPath } from "@/workspaces/files/artifact"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useSessionLayout } from "@/session/session-layout"
import { SESSION_OPEN_FILE_TAB } from "@/shell/state/session-tabs"
import {
  checkFileLinkExists,
  findFileLink,
  isAbsoluteLink,
  parseFileLink,
  type FileLinkSelection,
} from "./resolve-link"

// The file view does not expose line offsets, so a linked line scrolls to an estimate and the selection marks it.
const LINE_HEIGHT = 24

export function ArtifactMarkdownProvider(props: ParentProps) {
  const markdown = useMarkdown()
  const artifacts = useArtifactOpener()
  return (
    <MarkdownProvider
      readImage={markdown?.readImage}
      openLocalFile={artifacts.open}
      localFileExists={(href) => untrack(() => artifacts.exists(href))}
    >
      {props.children}
    </MarkdownProvider>
  )
}

export const { use: useArtifactOpener, provider: ArtifactOpenerProvider } = createSimpleContext({
  name: "ArtifactOpener",
  init: () => {
    const file = useFile()
    const location = useWorkspaceLocation()
    const layout = useSessionLayout()
    const [state, setState] = createStore({
      opened: 0,
      picker: { id: 0, query: "", pending: false },
      reveal: { id: 0, path: "" },
    })
    const lifetime = new AbortController()
    let click: AbortController | undefined
    onCleanup(() => {
      lifetime.abort()
      click?.abort()
    })
    const resolve = (href: string, base = "") => {
      const value = href
        .replaceAll("\\", "/")
        .replace(/:\d+(?::\d+)?$/, "")
        .replace(/(.)\/+$/, "$1")
      if (/^[a-z]:\//i.test(value) || value.startsWith("/")) return file.normalize(value)
      const relative = resolveArtifactPath(base, value)
      if (relative !== undefined) return file.normalize(relative)
      const root = location().directory.replaceAll("\\", "/").replace(/\/+$/, "")
      return file.normalize(resolveArtifactPath(`${root}/${base}`, value) ?? value)
    }
    const current = () => ({ directory: location().directory, sessionKey: layout.sessionKey() })
    const stillCurrent = (origin: ReturnType<typeof current>, signal?: AbortSignal) =>
      !signal?.aborted && location().directory === origin.directory && layout.sessionKey() === origin.sessionKey
    const reveal = (path: string, selection: FileLinkSelection) => {
      const tab = file.tab(path)
      file.setSelectedLines(path, { start: selection.start, end: selection.end })
      layout.view().setScroll(tab, {
        x: layout.view().scroll(tab)?.x ?? 0,
        y: Math.max(0, (selection.start - 4) * LINE_HEIGHT),
      })
      setState("reveal", (value) => ({ id: value.id + 1, path }))
    }
    const openResolved = async (
      path: string,
      origin: ReturnType<typeof current>,
      selection?: FileLinkSelection,
      signal?: AbortSignal,
    ) => {
      const tabs = layout.tabs()
      // Confirm the file exists before a tab appears for it. Always reread: V2 publishes no workspace file change
      // events, so a cached copy can be stale.
      await file.load(path, { force: true })
      if (!stillCurrent(origin, signal) || !file.get(path)?.loaded) return
      if (selection && artifactKind(path) === "text") reveal(path, selection)
      const tab = file.tab(path)
      tabs.open(tab)
      tabs.setActive(tab)
      layout.view().reviewPanel.open()
      setState("opened", (value) => value + 1)
    }
    const openPicker = (query: string) => {
      const tabs = layout.tabs()
      setState("picker", (value) => ({ id: value.id + 1, query, pending: true }))
      tabs.previewTab(SESSION_OPEN_FILE_TAB)
      tabs.setActive(SESSION_OPEN_FILE_TAB)
      layout.view().reviewPanel.open()
    }
    // A `base` (even empty) names one exact file: a link inside a previewed document, a listed entry, or an agent
    // preview. Without it the path comes from a message and may name a file anywhere in the workspace by its suffix.
    const open = async (href: string, base?: string) => {
      click?.abort()
      const controller = new AbortController()
      click = controller
      const origin = current()
      const parsed = parseFileLink(href)
      const direct = resolve(parsed.path, base)
      if (!direct) return
      if (base !== undefined || isAbsoluteLink(parsed.path))
        return openResolved(direct, origin, parsed.selection, controller.signal)
      const target = await findFileLink({ search: file.searchFiles, path: parsed.path, signal: controller.signal })
      if (!stillCurrent(origin, controller.signal)) return
      if (target?.kind === "picker") return openPicker(target.query)
      // With no match, the literal path still covers files the search index skips, such as an ignored `.env`.
      return openResolved(target?.path ?? direct, origin, parsed.selection, controller.signal)
    }
    // Messages style a path as a link only when this says the file exists.
    const exists = (href: string, base?: string) => {
      if (base === undefined)
        return checkFileLinkExists({
          search: file.searchFiles,
          resolve: file.normalize,
          exists: file.exists,
          href,
          signal: lifetime.signal,
        })
      const path = parseFileLink(href).path
      if (!path || path.startsWith("//") || path.startsWith("~")) return Promise.resolve(false)
      return file.exists(resolve(path, base))
    }
    const takePicker = () => {
      if (!state.picker.pending) return
      setState("picker", "pending", false)
      return state.picker.query
    }
    return {
      open,
      exists,
      resolve,
      opened: () => state.opened,
      picker: () => state.picker,
      takePicker,
      reveal: () => state.reveal,
    }
  },
})
