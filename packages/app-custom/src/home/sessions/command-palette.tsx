import { useDialog } from "@opencode/ui-custom/context/dialog"
import { createMemo, onCleanup } from "solid-js"
import { commandPaletteOptions, useCommand } from "@/shell/commands/command"
import { useGlobal } from "@/runtime/server/runtime"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection } from "@/runtime/server/registry"
import {
  createCommandPaletteCommandEntry,
  createServerSessionEntries,
  type CommandPaletteEntry,
} from "@/shell/commands/palette"
import { CommandPaletteView, matchesCommandPaletteEntry } from "@/shell/commands/dialog"
import { chatCapability } from "@/runtime/chats"
import { findSessionTab, useTabs } from "@/shell/tabs/tabs"

export function HomeCommandPalette(props: {
  server: ServerConnection.Any
  onSelectSession: (entry: CommandPaletteEntry) => void
}) {
  const command = useCommand()
  const dialog = useDialog()
  const global = useGlobal()
  const language = useLanguage()
  const tabs = useTabs()
  const server = global.ensureServerCtx(props.server)
  const chats = chatCapability(server.sdk)
  void chats.load()
  const state = { cleanup: undefined as (() => void) | void, committed: false }
  const commandEntries = createMemo(() => {
    const category = language.t("palette.group.commands")
    return commandPaletteOptions(command.options).map((option) => createCommandPaletteCommandEntry(option, category))
  })
  const sessions = createServerSessionEntries({
    server: ServerConnection.key(props.server),
    opened: server.projects.list,
    stored: () => server.sync.data.project,
    load: (search, signal) => server.sdk.api.session.list({ parentID: null, search, limit: 50 }, { signal }),
    get: (sessionID, signal) => server.sdk.api.session.get({ sessionID }, { signal }),
    untitled: () => language.t("command.session.new"),
    category: () => language.t("command.category.session"),
    chatRoot: () => chats.state.root,
    chatLabel: () => language.t("session.new.chats"),
    isChat: (session) =>
      !!findSessionTab(tabs.store, ServerConnection.key(props.server), session.id)?.chat,
  })

  const highlight = (item: CommandPaletteEntry | undefined) => {
    state.cleanup?.()
    state.cleanup = undefined
    if (item?.type !== "command") return
    state.cleanup = item.option?.onHighlight?.()
  }
  const select = (item: CommandPaletteEntry | undefined) => {
    if (!item) return
    state.committed = true
    state.cleanup = undefined
    dialog.close()
    if (item.type === "command") {
      item.option?.onSelect?.("palette")
      return
    }
    if (item.type === "session") props.onSelectSession(item)
  }
  const items = (query: string) => {
    if (!query) return commandEntries().slice(0, 5)
    return commandEntries().filter((entry) => matchesCommandPaletteEntry(entry, query))
  }

  onCleanup(() => {
    if (state.committed) return
    state.cleanup?.()
  })

  return (
    <CommandPaletteView
      placeholder={language.t("palette.search.placeholder.home")}
      items={items}
      sources={[sessions]}
      highlight={highlight}
      select={select}
      close={() => dialog.close()}
    />
  )
}
