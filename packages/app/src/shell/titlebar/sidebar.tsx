import { createEffect, createMemo, createUniqueId, For, mapArray, onCleanup, Show, type JSX } from "solid-js"
import { Key } from "@solid-primitives/keyed"
import { createStore } from "solid-js/store"
import { Schema } from "effect"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { Tooltip } from "@opencode/ui/tooltip"
import { TextInput } from "@opencode/ui/text-input"
import { Button } from "@opencode/ui/button"
import { useSessionLifecycleActions } from "@/session/lifecycle-actions"
import { DragDropProvider, PointerSensor } from "@dnd-kit/solid"
import { useSortable, isSortable } from "@dnd-kit/solid/sortable"
import { PointerActivationConstraints } from "@dnd-kit/dom"
import { RestrictToVerticalAxis } from "@dnd-kit/abstract/modifiers"
import { arrayMove } from "@dnd-kit/helpers"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection, serverName } from "@/runtime/server/registry"
import { useLanguage } from "@/runtime/i18n/language"
import { useLayout } from "@/shell/state/layout"
import { useSettings } from "@/settings/model"
import { Persist, persisted } from "@/runtime/persistence/storage"
import { Persistence } from "@/runtime/persistence/schema"
import { tabHref, tabKey, useTabs, type Tab } from "@/shell/tabs/tabs"
import { showToast } from "@/shell/notifications/toast"
import { useCommand } from "@/shell/commands/command"
import { getCompactRelativeTime } from "@/shell/time"
import { adjacentTabKey, mergeVisibleTabOrder } from "./tab-order"
import { TabNavItem } from "./tab-nav"
import { TitlebarTabStrip } from "./tab-strip"
import { createSidebarIndex } from "./sidebar-index"
import { createRecentClock } from "./sidebar-order"
import { SidebarProjectActions, SidebarWorktreeNewSession } from "./sidebar-project-actions"
import { createSidebarWorktrees, visibleWorktreeSessions } from "./sidebar-worktrees"
import { createSidebarSelection } from "./sidebar-selection"
import { navigationSession, sessionAttention } from "@/shell/notifications/session-attention"
import {
  attentionGroups,
  orderSidebarProjects,
  pinnedSessions,
  projectKey,
  recentSessions,
  rootSessions,
  searchSessions,
  sessionKey,
  sidebarProjects,
  visibleSessions,
  type SidebarSession,
} from "./sidebar-model"

const SidebarState = Persistence.struct({
  attention: Schema.Boolean,
  order: Persistence.array(Schema.String),
  collapsed: Persistence.record(Schema.Boolean),
  pins: Persistence.array(Schema.String),
})
const RECENT_PAGE_SIZE = 5

export function SessionSidebar(props: { header: JSX.Element; children: JSX.Element; currentTab?: Tab }) {
  const global = useGlobal()
  const layout = useLayout()
  const tabs = useTabs()
  const settings = useSettings()
  const language = useLanguage()
  const dateFormat = createMemo(
    () => new Intl.DateTimeFormat(language.intl(), { dateStyle: "full", timeStyle: "long" }),
  )
  const command = useCommand()
  const lifecycle = useSessionLifecycleActions()
  const [saved, setSaved, , ready] = persisted(Persist.global("sidebar-navigation"), SidebarState, {
    attention: true,
    order: [],
    collapsed: {},
    pins: [],
  })
  const [state, setState] = createStore({
    now: Date.now(),
    limits: {} as Record<string, number>,
    recentLimit: RECENT_PAGE_SIZE,
    drag: undefined as string | undefined,
    query: "",
  })
  const clock = createRecentClock()
  const indexes = mapArray(global.servers.list, (connection) => {
    const ctx = global.ensureServerCtx(connection)
    return { connection, ctx, index: createSidebarIndex(ctx, clock), worktrees: createSidebarWorktrees(ctx) }
  })
  const gesture = { dragged: false }
  const timer = setInterval(() => setState("now", Date.now()), 60_000)
  onCleanup(() => clearInterval(timer))
  const current = () => {
    const route = layout.route()
    return route.type === "session" ? sessionKey(route.server, route.sessionId) : undefined
  }
  command.register("sidebar-tab-cycle", () =>
    [-1, 1].map((offset) => ({
      id: offset === -1 ? "tab.prev" : "tab.next",
      category: "tab",
      title: "",
      hidden: true,
      keybind: offset === -1 ? "mod+option+ArrowLeft,ctrl+shift+tab" : "mod+option+ArrowRight,ctrl+tab",
      onSelect: () => {
        const key = adjacentTabKey(
          tabs.store.map(tabKey),
          props.currentTab ? tabKey(props.currentTab) : undefined,
          offset === -1 ? -1 : 1,
        )
        const next = tabs.store.find((tab) => tabKey(tab) === key)
        if (next) tabs.select(next)
      },
    })),
  )
  const sessions = createMemo(() =>
    rootSessions(
      indexes().flatMap(({ connection, ctx, index }) => {
        const server = ServerConnection.key(connection)
        const known = new Map(
          Object.values(index.state.rows)
            .filter(Boolean)
            .map((row) => [row.session.id, row]),
        )
        const route = layout.route()
        if (route.type === "session" && route.server === server && !known.has(route.sessionId)) {
          const session = ctx.data.session.get(route.sessionId)
          if (session) known.set(session.id, { session })
        }
        const tab = props.currentTab
        if (tab?.type === "session" && tab.server === server && !known.has(tab.sessionId)) {
          const session = ctx.data.session.get(tab.sessionId)
          if (session) known.set(session.id, { session })
        }
        return [...known.values()].map((row): SidebarSession => {
          const session = navigationSession(row, ctx.data.session.get(row.session.id))
          return {
            ...row,
            session,
            server,
            key: sessionKey(server, session.id),
            project: projectKey(server, { id: session.projectID, worktree: session.location.directory }),
            recentRank: index.ranks[session.id],
            ...sessionAttention({
              ...row,
              session,
              notifications: ctx.notification.session.unseen(session.id),
              autoApprove: settings.permissions.autoApprove(),
            }),
          }
        })
      }),
      current(),
      props.currentTab?.type === "session"
        ? sessionKey(props.currentTab.server, props.currentTab.sessionId)
        : undefined,
    ),
  )
  const projectGroups = createMemo(() =>
    indexes().flatMap(({ connection, ctx }) => {
      const server = ServerConnection.key(connection)
      const known = [...ctx.sync.data.project.filter((project) => project.id !== "global"), ...ctx.projects.list()]
      return sidebarProjects(
        server,
        known,
        sessions().rows.filter((row) => row.server === server),
      ).map((project) => ({
        ...project,
        connection,
        serverName: serverName(connection),
      }))
    }),
  )
  const projects = createMemo(() => orderSidebarProjects(projectGroups(), saved.order))
  let projectList: HTMLDivElement | undefined
  const projectOrder = createMemo(() => ({
    keys: projects().map((project) => project.key),
    focused: projectList?.contains(document.activeElement) ? document.activeElement : undefined,
  }))
  createEffect(() => {
    const focused = projectOrder().focused
    // Occupancy changes move the same keyed header between blocks, which can blur it.
    if (focused instanceof HTMLElement && focused.isConnected && document.activeElement === document.body)
      focused.focus({ preventScroll: true })
  })
  createEffect(() => {
    if (!ready()) return
    const missing = projects()
      .map((group) => group.key)
      .filter((key) => !saved.order.includes(key))
    if (missing.length) setSaved("order", [...saved.order, ...missing])
  })
  const pins = createMemo(() => new Set(saved.pins))
  // Resolve against eligible rows without pruning preferences when a server/index is unavailable.
  const pinned = createMemo(() => pinnedSessions(sessions().rows, saved.pins))
  const groups = createMemo(() => attentionGroups(sessions().rows, state.now, sessions().current, saved.pins))
  const recentRows = createMemo(() => recentSessions(sessions().rows.filter((row) => !pins().has(row.key))))
  const recent = createMemo(() => visibleSessions(recentRows(), state.recentLimit, sessions().current))
  const recentMore = () => recentRows().length > recent().length
  const query = createMemo(() => state.query.trim())
  const results = createMemo(() => searchSessions(sessions().rows, query(), projectGroups()))
  const worktrees = createMemo(
    () =>
      new Map(
        projects().map((project) => {
          const entry = indexes().find((entry) => ServerConnection.key(entry.connection) === project.server)!
          return [project.key, entry.worktrees.group(project, sessions().rows)]
        }),
      ),
  )
  createEffect(() => {
    if (!ready() || saved.attention || query()) return
    projects()
      .filter((project) => project.occupied && !saved.collapsed[project.key])
      .forEach((project) => {
        const entry = indexes().find((entry) => ServerConnection.key(entry.connection) === project.server)!
        void entry.worktrees.load(() => {
          if (!ready() || saved.attention || query() || saved.collapsed[project.key]) return
          const current = projects().find((item) => item.key === project.key)
          if (current?.occupied) return { project: current, rows: sessions().rows }
        })
      })
  })
  const projectRows = (key: string) =>
    visibleWorktreeSessions(worktrees().get(key)!, key, saved.collapsed, state.limits, sessions().current)
  // Match rendered order, retaining the first occurrence of sessions repeated in project groups.
  const selectable = createMemo(() => {
    const rows = query()
      ? results()
      : saved.attention
        ? [...groups().priority, ...groups().pinned, ...groups().days.flatMap((day) => day.rows), ...groups().current]
        : [...pinned(), ...recent(), ...projects().flatMap((project) => projectRows(project.key))]
    const seen = new Set<string>()
    return rows.filter((row) => {
      if (seen.has(row.key)) return false
      seen.add(row.key)
      return true
    })
  })
  const selection = createSidebarSelection({
    rows: selectable,
    view: () => JSON.stringify([state.query, saved.attention]),
    pending: lifecycle.pending,
  })
  const loading = () => indexes().some((entry) => entry.index.state.loading)
  const searchID = createUniqueId()
  let searchInput: HTMLInputElement | undefined
  let searchResults: HTMLDivElement | undefined
  const scroll = { attention: 0, projects: 0 }
  let scroller: HTMLDivElement | undefined
  const toggle = () => {
    if (scroller) scroll[saved.attention ? "attention" : "projects"] = scroller.scrollTop
    setSaved("attention", !saved.attention)
    queueMicrotask(() => {
      if (scroller) scroller.scrollTop = scroll[saved.attention ? "attention" : "projects"]
    })
  }
  const move = (key: string, to: number) => {
    const focused = document.activeElement
    const order = projects().map((group) => group.key)
    const from = order.indexOf(key)
    if (from < 0 || to < 0 || to >= order.length) return
    order.splice(from, 1)
    order.splice(to, 0, key)
    setSaved(
      "order",
      mergeVisibleTabOrder(
        saved.order,
        projects().map((project) => project.key),
        order,
      ),
    )
    queueMicrotask(() => {
      if (focused instanceof HTMLElement && focused.isConnected && document.activeElement === document.body)
        focused.focus({ preventScroll: true })
    })
  }
  const Row = (props: { item: SidebarSession; compact?: boolean }) => {
    // Recent's monotonic rank and metadata updates are not interaction timestamps.
    const at = createMemo(() => props.item.messageAt ?? props.item.session.time.created)
    const time = createMemo(() => {
      const date = new Date(at())
      if (!Number.isFinite(date.getTime())) return
      return { at: at(), dateTime: date.toISOString(), title: dateFormat().format(date) }
    })
    const ctx = () => indexes().find((entry) => ServerConnection.key(entry.connection) === props.item.server)?.ctx
    const tab = () =>
      tabs.store.find(
        (tab) => tab.type === "session" && tab.server === props.item.server && tab.sessionId === props.item.session.id,
      ) ?? { type: "session" as const, server: props.item.server, sessionId: props.item.session.id }
    return (
      <TabNavItem
        href={tabHref(tab())}
        server={props.item.server}
        session={props.item.session}
        preparing={false}
        orientation="vertical"
        sidebarActions
        timestamp={
          time() ? { ...time()!, label: getCompactRelativeTime(time()!.at, language.plural, state.now) } : undefined
        }
        compact={props.compact}
        projectLabel={projectLabel(props.item.project)}
        closable={tabs.store.some((value) => tabKey(value) === tabKey(tab()))}
        active={sessions().current === props.item.key}
        unread={props.item.attention !== undefined}
        pinned={pins().has(props.item.key)}
        selectionMode={selection.state.mode}
        selected={selection.state.keys.includes(props.item.key)}
        selectionPending={lifecycle.pending()}
        onActivate={(event) => selection.activate(props.item.key, event)}
        onTogglePin={
          ready()
            ? () =>
                setSaved("pins", (keys) =>
                  keys.includes(props.item.key)
                    ? keys.filter((key) => key !== props.item.key)
                    : [...keys, props.item.key],
                )
            : undefined
        }
        onNavigate={() =>
          tabs.select(tabs.addSessionTab({ server: props.item.server, sessionId: props.item.session.id }))
        }
        onClose={() => {
          const index = tabs.store.findIndex((value) => tabKey(value) === tabKey(tab()))
          if (index !== -1) tabs.closeTab(index)
        }}
        onRename={async (title) => {
          const context = ctx()
          if (!context) return
          await context.sdk.api.session
            .rename({ sessionID: props.item.session.id, title })
            .then(() => {
              context.data.session.remember({ ...props.item.session, title })
            })
            .catch((error) =>
              showToast({
                title: language.t("common.requestFailed"),
                description: error instanceof Error ? error.message : undefined,
              }),
            )
        }}
      />
    )
  }
  const projectLabel = (key: string) => {
    const project = projects().find((project) => project.key === key)
    if (!project) return
    return indexes().length > 1
      ? language.t("sidebar.project.server", { project: project.name, server: project.serverName })
      : project.name
  }
  const Section = (props: { title: string; rows: SidebarSession[]; children?: JSX.Element }) => {
    let element: HTMLElement | undefined
    const rows = createMemo(() => ({
      items: props.rows,
      focused: element?.contains(document.activeElement) ? document.activeElement : undefined,
    }))
    createEffect(() => {
      const focused = rows().focused
      // Moving a keyed DOM node can blur it even though the row remains mounted.
      if (focused instanceof HTMLElement && focused.isConnected && document.activeElement === document.body)
        focused.focus({ preventScroll: true })
    })
    return (
      <Show when={rows().items.length}>
        <section ref={element} class="mt-4 first:mt-0">
          <h2 class="mb-1 px-1.5 text-[13px] leading-4 text-v2-text-text-muted">{props.title}</h2>
          <div class="flex flex-col gap-1">
            <Key each={rows().items} by="key">
              {(item) => <Row item={item()} />}
            </Key>
          </div>
          {props.children}
        </section>
      </Show>
    )
  }
  return (
    <>
      <div class="mb-4 flex h-7 shrink-0 items-center justify-between gap-2 [app-region:no-drag]">
        {props.header}
        <Tooltip value={language.t(saved.attention ? "sidebar.projects.show" : "sidebar.attention.show")}>
          <span class="relative flex">
            <IconButton
              icon={<Icon name="bell" />}
              variant="ghost-muted"
              size="normal"
              onClick={toggle}
              aria-label={language.t("sidebar.attention.toggle")}
              aria-pressed={saved.attention}
              state={saved.attention ? "pressed" : undefined}
            />
            <Show when={groups().priority.length}>
              <span
                data-slot="sidebar-pending"
                class="pointer-events-none absolute end-1 top-1 size-1.5 rounded-full bg-v2-icon-icon-accent"
                aria-label={language.t("sidebar.attention.pending")}
              />
            </Show>
          </span>
        </Tooltip>
      </div>
      {props.children}
      <div class="shrink-0 pt-4 [app-region:no-drag]" onKeyDown={selection.escape}>
        <TextInput
          ref={searchInput}
          type="search"
          dir="auto"
          class="!w-full"
          leadingIcon={<Icon name="magnifying-glass" size="small" />}
          value={state.query}
          placeholder={language.t("sidebar.search.placeholder")}
          aria-label={language.t("sidebar.search.label")}
          aria-controls={query() ? searchID : undefined}
          aria-describedby={`${searchID}-hint`}
          showClearButton={!!state.query}
          clearLabel={language.t("sidebar.search.clear")}
          onClearClick={() => {
            setState("query", "")
            searchInput?.focus()
          }}
          onInput={(event) => setState("query", event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape" && selection.state.mode) {
              selection.escape(event)
              return
            }
            if (event.isComposing || event.altKey || event.metaKey || event.ctrlKey || event.shiftKey) return
            if (event.key === "Escape" && state.query) {
              event.preventDefault()
              event.stopPropagation()
              setState("query", "")
              return
            }
            if (!query() || (event.key !== "ArrowDown" && event.key !== "Enter")) return
            const first = searchResults?.querySelector<HTMLAnchorElement>("[data-titlebar-tab-link]")
            if (!first) return
            event.preventDefault()
            event.stopPropagation()
            first.focus()
            first.scrollIntoView({ block: "nearest", inline: "nearest" })
            if (event.key === "Enter") first.click()
          }}
        />
        <span id={`${searchID}-hint`} class="sr-only">
          {language.t("sidebar.search.hint")}
        </span>
      </div>
      <div class="shrink-0 pt-2 [app-region:no-drag]" onKeyDown={selection.escape}>
        <Show
          when={selection.state.mode}
          fallback={
            <Button variant="ghost" size="small" onClick={selection.start}>
              {language.t("sidebar.selection.start")}
            </Button>
          }
        >
          <div
            data-slot="sidebar-selection"
            role="group"
            aria-label={language.t("sidebar.selection.start")}
            aria-description={language.t("sidebar.selection.hint")}
            class="flex flex-wrap items-center gap-1"
            aria-busy={lifecycle.pending()}
          >
            <span role="status" class="w-full px-1.5 text-[13px] leading-4 text-v2-text-text-muted">
              {language.plural("sidebar.selection.count", selection.state.keys.length)}
            </span>
            <Button
              variant="ghost"
              size="small"
              disabled={lifecycle.pending() || !selectable().length}
              onClick={selection.all}
              title={language.t("sidebar.selection.hint")}
            >
              {language.t("sidebar.selection.all")}
            </Button>
            <Button variant="ghost" size="small" disabled={lifecycle.pending()} onClick={selection.clear}>
              {language.t("sidebar.selection.clear")}
            </Button>
            <Button
              variant="ghost"
              size="small"
              disabled={lifecycle.pending() || !selection.state.keys.length}
              onClick={() => void lifecycle.archiveMany(selection.selected(), selection.complete)}
            >
              {language.t("common.archive")}
            </Button>
            <Button
              variant="ghost"
              size="small"
              disabled={lifecycle.pending() || !selection.state.keys.length}
              onClick={() => lifecycle.showDeleteMany(() => selection.selected(), selection.complete)}
              style={{ color: "var(--v2-state-fg-danger)" }}
            >
              {language.t("common.delete")}…
            </Button>
          </div>
        </Show>
      </div>
      <nav
        onKeyDown={selection.escape}
        aria-label={language.t("sidebar.sessions")}
        ref={scroller}
        class="min-h-0 flex-1 overflow-y-auto overflow-x-hidden pt-4 [app-region:no-drag]"
        data-slot="session-sidebar"
        data-mode={query() ? "search" : saved.attention ? "attention" : "projects"}
      >
        <Show
          when={tabs.store.some(
            (tab) => tab.type === "draft" || (tab.type === "session" && tabs.pendingSession(tab.server, tab.sessionId)),
          )}
        >
          {/* Keep numbered tab shortcuts registered while search hides these rows. */}
          <div hidden={!!query()}>
            <TitlebarTabStrip
              orientation="vertical"
              shortcuts={false}
              tabs={tabs.store.filter(
                (tab) =>
                  tab.type === "draft" || (tab.type === "session" && tabs.pendingSession(tab.server, tab.sessionId)),
              )}
              currentTab={props.currentTab}
              onNavigate={(tab) => tabs.select(tab)}
              onClose={(tab) => tabs.closeTab(tabs.store.findIndex((item) => tabKey(item) === tabKey(tab)))}
              onReorder={(keys) => tabs.reorder(keys)}
            />
          </div>
        </Show>
        <Show when={!query() && !sessions().rows.length && loading()}>
          <p class="px-1.5 text-[13px] leading-4 text-v2-text-text-muted" role="status">
            {language.t("sidebar.sessions.loading")}
          </p>
        </Show>
        <For each={indexes().filter((entry) => entry.index.state.error)}>
          {(entry) => (
            <button
              class="w-full rounded-[6px] px-1.5 py-2 text-start text-[13px] leading-4 text-v2-text-text-muted hover:bg-v2-background-bg-layer-02"
              onClick={entry.index.retry}
            >
              {language.t("sidebar.sessions.retry", { server: serverName(entry.connection) })}
            </button>
          )}
        </For>
        <Show when={query()}>
          <div id={searchID} ref={searchResults} aria-busy={loading()}>
            <p class="mb-2 px-1.5 text-[13px] leading-4 text-v2-text-text-muted" role="status">
              {loading()
                ? language.t("sidebar.sessions.loading")
                : indexes().some((entry) => entry.index.state.error)
                  ? language.t("sidebar.search.incomplete")
                  : results().length
                    ? language.plural("sidebar.search.results", results().length)
                    : language.t("sidebar.search.empty")}
            </p>
            <div class="flex flex-col gap-1">
              <Key each={results()} by="key">
                {(item) => <Row item={item()} />}
              </Key>
            </div>
          </div>
        </Show>
        <Show when={!query()}>
          <Show
            when={saved.attention}
            fallback={
              <>
                <Section title={language.t("sidebar.sessions.pinned")} rows={pinned()} />
                <Section title={language.t("sidebar.sessions.recent")} rows={recent()}>
                  <Show
                    when={
                      recentMore() ||
                      recent().length > visibleSessions(recentRows(), RECENT_PAGE_SIZE, sessions().current).length
                    }
                  >
                    <button
                      type="button"
                      class="mt-1 block h-7 w-fit max-w-full rounded-[6px] px-1.5 text-start text-[13px] leading-4 text-v2-text-text-muted hover:text-v2-text-text-base focus-visible:outline-none focus-visible:bg-v2-background-bg-layer-02"
                      onClick={() =>
                        setState("recentLimit", (limit) => (recentMore() ? limit + RECENT_PAGE_SIZE : RECENT_PAGE_SIZE))
                      }
                    >
                      {language.t(recentMore() ? "sidebar.sessions.recent.more" : "sidebar.sessions.recent.fewer")}
                    </button>
                  </Show>
                </Section>
                <div ref={projectList} class="mt-4 flex flex-col gap-2">
                  <h2 class="px-1.5 text-[13px] leading-4 text-v2-text-text-muted">
                    {language.t("sidebar.projects.heading")}
                  </h2>
                  <DragDropProvider
                    sensors={[
                      PointerSensor.configure({
                        activationConstraints: [new PointerActivationConstraints.Distance({ value: 4 })],
                      }),
                    ]}
                    modifiers={[RestrictToVerticalAxis]}
                    onDragStart={(event) => {
                      gesture.dragged = true
                      setState("drag", event.operation.source?.id.toString())
                    }}
                    onDragEnd={(event) => {
                      setState("drag", undefined)
                      const source = event.operation.source
                      if (event.canceled || !isSortable(source)) return
                      setSaved(
                        "order",
                        mergeVisibleTabOrder(
                          saved.order,
                          projects().map((project) => project.key),
                          arrayMove(
                            projects().map((project) => project.key),
                            source.initialIndex,
                            source.index,
                          ),
                        ),
                      )
                    }}
                  >
                    {/* Keep headers and open menus mounted across navigation-index and metadata updates. */}
                    <For each={projectOrder().keys}>
                      {(key, index) => {
                        const initial = projects().find((project) => project.key === key)
                        if (!initial) return
                        const project = createMemo<typeof initial>(
                          (previous) => projects().find((project) => project.key === key) ?? previous,
                          initial,
                        )
                        const rows = createMemo(() => sessions().rows.filter((row) => row.project === key))
                        const collapsed = () => saved.collapsed[key] ?? false
                        const tree = () => worktrees().get(key)!
                        const visible = () =>
                          collapsed()
                            ? projectRows(key)
                            : visibleSessions(tree().root, state.limits[key] ?? 5, sessions().current)
                        return (
                          <SortableProject id={key} index={index()}>
                            {(handle) => (
                              <>
                                <div class="group/project flex h-7 items-center gap-1 rounded-[6px] hover:bg-v2-background-bg-layer-02">
                                  <button
                                    ref={handle}
                                    class="flex h-7 min-w-0 flex-1 touch-none items-center gap-1.5 px-1.5 text-start text-[13px] leading-4 text-v2-text-text-muted"
                                    classList={{
                                      "cursor-grab": state.drag !== key,
                                      "cursor-grabbing": state.drag === key,
                                    }}
                                    title={language.t("sidebar.project.reorderHint")}
                                    aria-description={language.t("sidebar.project.reorderHint")}
                                    onPointerDown={() => {
                                      gesture.dragged = false
                                    }}
                                    onKeyDown={(event) => {
                                      if (!event.altKey || (event.key !== "ArrowUp" && event.key !== "ArrowDown"))
                                        return
                                      event.preventDefault()
                                      move(key, index() + (event.key === "ArrowUp" ? -1 : 1))
                                    }}
                                    aria-expanded={!collapsed()}
                                    onClick={(event) => {
                                      if (event.detail > 0 && gesture.dragged) return
                                      setSaved("collapsed", key, !collapsed())
                                    }}
                                  >
                                    <Icon
                                      name={collapsed() ? "chevron-right" : "chevron-down"}
                                      size="small"
                                      class={collapsed() ? "rtl:rotate-180" : ""}
                                    />
                                    <span dir="auto" class="min-w-0 truncate" title={projectLabel(key)}>
                                      {projectLabel(key)}
                                    </span>
                                    <Show when={collapsed() && rows().some((row) => row.attention !== undefined)}>
                                      <span
                                        class="size-1.5 shrink-0 rounded-full bg-v2-icon-icon-accent"
                                        aria-label={language.t("sidebar.attention.pending")}
                                      />
                                    </Show>
                                  </button>
                                  <SidebarProjectActions
                                    connection={project().connection}
                                    directory={project().directory}
                                    metadata={project().metadata}
                                  />
                                </div>
                                <div class="flex flex-col gap-1">
                                  <Key each={visible()} by="key">
                                    {(item) => <Row item={item()} compact />}
                                  </Key>
                                </div>
                                <Show when={!collapsed() && tree().root.length > visible().length}>
                                  <button
                                    class="h-7 px-1.5 text-[13px] leading-4 text-v2-text-text-muted hover:text-v2-text-text-base"
                                    onClick={() => setState("limits", key, (value = 5) => value + 5)}
                                  >
                                    {language.t("sidebar.sessions.more")}
                                  </button>
                                </Show>
                                <Show when={!collapsed()}>
                                  <Key each={tree().groups} by="key">
                                    {(group) => {
                                      const collapsed = () => saved.collapsed[group().key] ?? false
                                      const visible = () =>
                                        collapsed()
                                          ? []
                                          : visibleSessions(
                                              group().rows,
                                              state.limits[group().key] ?? 5,
                                              sessions().current,
                                            )
                                      const id = createUniqueId()
                                      return (
                                        <section data-worktree-key={group().key} class="ms-3 mt-2">
                                          <div class="group/worktree flex h-7 items-center gap-1 rounded-[6px] hover:bg-v2-background-bg-layer-02">
                                            <button
                                              type="button"
                                              class="flex h-7 min-w-0 flex-1 items-center gap-1.5 px-1.5 text-start text-[13px] leading-4 text-v2-text-text-muted focus-visible:outline-none focus-visible:bg-v2-background-bg-layer-02"
                                              aria-expanded={!collapsed()}
                                              aria-controls={id}
                                              title={group().directory}
                                              onClick={() => setSaved("collapsed", group().key, !collapsed())}
                                            >
                                              <Icon
                                                name={collapsed() ? "chevron-right" : "chevron-down"}
                                                size="small"
                                                class={collapsed() ? "rtl:rotate-180" : ""}
                                              />
                                              <span dir="auto" class="min-w-0 truncate">
                                                {language.plural("sidebar.worktree.heading", group().rows.length, {
                                                  worktree: group().name,
                                                })}
                                              </span>
                                              <Show
                                                when={
                                                  collapsed() && group().rows.some((row) => row.attention !== undefined)
                                                }
                                              >
                                                <span
                                                  class="size-1.5 shrink-0 rounded-full bg-v2-icon-icon-accent"
                                                  aria-label={language.t("sidebar.attention.pending")}
                                                />
                                              </Show>
                                            </button>
                                            <SidebarWorktreeNewSession
                                              connection={project().connection}
                                              directory={group().directory}
                                              name={group().name}
                                            />
                                          </div>
                                          <div id={id} class="flex flex-col gap-1">
                                            <Key each={visible()} by="key">
                                              {(item) => <Row item={item()} compact />}
                                            </Key>
                                          </div>
                                          <Show when={!collapsed() && group().rows.length > visible().length}>
                                            <button
                                              type="button"
                                              class="h-7 px-1.5 text-[13px] leading-4 text-v2-text-text-muted hover:text-v2-text-text-base"
                                              onClick={() => setState("limits", group().key, (value = 5) => value + 5)}
                                            >
                                              {language.t("sidebar.sessions.more")}
                                            </button>
                                          </Show>
                                        </section>
                                      )
                                    }}
                                  </Key>
                                </Show>
                              </>
                            )}
                          </SortableProject>
                        )
                      }}
                    </For>
                  </DragDropProvider>
                </div>
              </>
            }
          >
            <section class="mt-4 first:mt-0">
              <h2 class="mb-1 px-1.5 text-[13px] leading-4 text-v2-text-text-muted">
                {language.t("sidebar.sessions.priority")}
              </h2>
              <Show
                when={groups().priority.length}
                fallback={
                  <p class="px-1.5 text-[13px] leading-4 text-v2-text-text-muted">
                    {language.t("sidebar.attention.empty")}
                  </p>
                }
              >
                <div class="flex flex-col gap-1">
                  <Key each={groups().priority} by="key">
                    {(item) => <Row item={item()} />}
                  </Key>
                </div>
              </Show>
            </section>
            <Section title={language.t("sidebar.sessions.pinned")} rows={groups().pinned} />
            <Key each={groups().days} by="start">
              {(day) => (
                <Section
                  title={
                    day().index === 0
                      ? language.t("sidebar.sessions.today")
                      : day().index === 1
                        ? language.t("sidebar.sessions.yesterday")
                        : new Intl.DateTimeFormat(language.intl(), {
                            weekday: "long",
                            month: "short",
                            day: "numeric",
                          }).format(day().start)
                  }
                  rows={day().rows}
                />
              )}
            </Key>
            <Section title={language.t("sidebar.sessions.current")} rows={groups().current} />
            <Show
              when={
                !groups().priority.length &&
                !groups().pinned.length &&
                !groups().current.length &&
                !groups().days.some((day) => day.rows.length) &&
                !indexes().some((entry) => entry.index.state.loading || entry.index.state.error)
              }
            >
              <p class="px-1.5 text-[13px] leading-4 text-v2-text-text-muted">{language.t("sidebar.sessions.empty")}</p>
            </Show>
          </Show>
        </Show>
      </nav>
    </>
  )
}

function SortableProject(props: {
  id: string
  index: number
  children: (handle: (element: HTMLButtonElement) => void) => JSX.Element
}) {
  const sortable = useSortable({
    get id() {
      return props.id
    },
    get index() {
      return props.index
    },
  })
  return (
    <section
      ref={sortable.ref}
      data-project-key={props.id}
      data-dragging={sortable.isDragSource()}
      class="relative data-[dragging=true]:z-10 data-[dragging=true]:bg-v2-background-bg-layer-02"
    >
      {props.children((element) => {
        sortable.handleRef(element)
      })}
    </section>
  )
}
