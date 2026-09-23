import { type ParentProps } from "solid-js"
import { createStore } from "solid-js/store"
import { createSimpleContext } from "@opencode/ui-custom/context"
import { MarkdownProvider, useMarkdown } from "@opencode/session-ui-custom/context/markdown"
import { useFile } from "@/workspaces/files/model"
import { resolveArtifactPath } from "@/workspaces/files/artifact"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useSessionLayout } from "@/session/session-layout"

export function ArtifactMarkdownProvider(props: ParentProps) {
  const markdown = useMarkdown()
  const artifacts = useArtifactOpener()
  return (
    <MarkdownProvider readImage={markdown?.readImage} openLocalFile={artifacts.open}>
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
    const [state, setState] = createStore({ opened: 0 })
    const resolve = (href: string, base = "") => {
      const value = href.replaceAll("\\", "/").replace(/:\d+(?::\d+)?$/, "")
      if (/^[a-z]:\//i.test(value) || value.startsWith("/")) return file.normalize(value)
      const relative = resolveArtifactPath(base, value)
      if (relative !== undefined) return file.normalize(relative)
      const root = location().directory.replaceAll("\\", "/").replace(/\/+$/, "")
      return file.normalize(resolveArtifactPath(`${root}/${base}`, value) ?? value)
    }
    const open = async (href: string, base?: string) => {
      const path = resolve(href, base)
      if (!path) return
      const directory = location().directory
      const sessionKey = layout.sessionKey()
      const tabs = layout.tabs()
      await file.load(path)
      if (location().directory !== directory || layout.sessionKey() !== sessionKey || !file.get(path)?.loaded) return
      const tab = file.tab(path)
      tabs.open(tab)
      tabs.setActive(tab)
      layout.view().reviewPanel.open()
      setState("opened", (value) => value + 1)
    }
    return { open, resolve, opened: () => state.opened }
  },
})
