import { createEffect, createMemo, createUniqueId, For, onCleanup, Show, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { Schema } from "effect"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { Tooltip } from "@opencode/ui/tooltip"
import { TextInput } from "@opencode/ui/text-input"
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
import { displayName } from "@/shell/layout/helpers"
import { tabHref, tabKey, useTabs, type Tab } from "@/shell/tabs/tabs"
import { showToast } from "@/shell/notifications/toast"
import { useCommand } from "@/shell/commands/command"
import { adjacentTabKey } from "./tab-order"
import { TabNavItem } from "./tab-nav"
import { TitlebarTabStrip } from "./tab-strip"
import { createSidebarIndex } from "./sidebar-index"
import {
  attentionGroups,
  firstAttention,
  pinnedSessions,
  projectKey,
  rootSessions,
  searchSessions,
  sessionKey,
  visibleSessions,
  type SidebarSession,
} from "./sidebar-model"

const SidebarState = Persistence.struct({
  attention: Schema.Boolean,
  order: Persistence.array(Schema.String),
  collapsed: Persistence.record(Schema.Boolean),
  pins: Persistence.array(Schema.String),
})

export function SessionSidebar(props: { header: JSX.Element; children: JSX.Element; currentTab?: Tab }) {
  const global = useGlobal()
  const layout = useLayout()
  const tabs = useTabs()
  const settings = useSettings()
  const language = useLanguage()
  const command = useCommand()
  const [saved, setSaved, , ready] = persisted(Persist.global("sidebar-navigation"), SidebarState, {
    attention: true,
    order: [],
    collapsed: {},
    pins: [],
  })
  const [state, setState] = createStore({
    now: Date.now(),
    limits: {} as Record<string, number>,
    drag: undefined as string | undefined,
    query: "",
  })
  const indexes = createMemo(() =>
    global.servers.list().map((connection) => {
      const ctx = global.ensureServerCtx(connection)
      return { connection, ctx, index: createSidebarIndex(ctx) }
    }),
  )
  const gesture = { dragged: false }
  const timer = setInterval(() => setState("now", Date.now()), 60_000)
  onCleanup(() => clearInterval(timer))
  const projectGroups = createMemo(() =>
    indexes().flatMap(({ connection, ctx, index }) => {
      const server = ServerConnection.key(connection)
      const known = [...ctx.sync.data.project.filter((project) => project.id !== "global"), ...ctx.projects.list()]
      const entries = [
        ...known,
        ...Object.values(index.state.rows)
          .filter(Boolean)
          .map((row) => ({
            id: row.session.projectID,
            worktree: row.session.location.directory,
          })),
      ]
      return [
        ...new Map(
          entries
            .map((project) => {
              const key = projectKey(server, project)
              return [
                key,
                {
                  key,
                  server,
                  directory: project.worktree,
                  name: displayName(project),
                  serverName: serverName(connection),
                },
              ] as const
            })
            .reverse(),
        ).values(),
      ]
    }),
  )
  const projects = createMemo(() =>
    projectGroups().toSorted((a, b) => {
      const ai = saved.order.indexOf(a.key)
      const bi = saved.order.indexOf(b.key)
      return (
        (ai < 0 ? Infinity : ai) - (bi < 0 ? Infinity : bi) ||
        a.name.localeCompare(b.name) ||
        a.key.localeCompare(b.key)
      )
    }),
  )
  createEffect(() => {
    if (!ready()) return
    const missing = projects()
      .map((group) => group.key)
      .filter((key) => !saved.order.includes(key))
    if (missing.length) setSaved("order", [...saved.order, ...missing])
  })
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
        return [...known.values()].map((row): SidebarSession => {
          const session = ctx.data.session.get(row.session.id) ?? row.session
          const viewed = session.time.viewed ?? 0
          const unread =
            row.unreadAt !== undefined && (session.time.idle ?? row.unreadAt) > viewed ? row.unreadAt : undefined
          return {
            ...row,
            session,
            server,
            key: sessionKey(server, session.id),
            project: projectKey(server, { id: session.projectID, worktree: session.location.directory }),
            attention: firstAttention(
              unread,
              ...ctx.notification.session.unseen(session.id).map((notification) => notification.time),
              settings.permissions.autoApprove() ? undefined : row.permissionAt,
              row.questionAt,
            ),
          }
        })
      }),
      current(),
    ),
  )
  const pins = createMemo(() => new Set(saved.pins))
  // Resolve against eligible rows without pruning preferences when a server/index is unavailable.
  const pinned = createMemo(() => pinnedSessions(sessions().rows, saved.pins))
  const groups = createMemo(() => attentionGroups(sessions().rows, state.now, sessions().current, saved.pins))
  const recent = createMemo(() =>
    visibleSessions(
      sessions().rows.filter((row) => !pins().has(row.key)),
      5,
      sessions().current,
    ),
  )
  const query = createMemo(() => state.query.trim())
  const results = createMemo(() => searchSessions(sessions().rows, query(), projectGroups()))
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
    const order = projects().map((group) => group.key)
    const from = order.indexOf(key)
    if (from < 0 || to < 0 || to >= order.length) return
    order.splice(from, 1)
    order.splice(to, 0, key)
    setSaved("order", order)
  }
  const row = (item: SidebarSession, compact = false) => {
    const ctx = () => indexes().find((entry) => ServerConnection.key(entry.connection) === item.server)?.ctx
    const tab = () =>
      tabs.store.find(
        (tab) => tab.type === "session" && tab.server === item.server && tab.sessionId === item.session.id,
      ) ?? { type: "session" as const, server: item.server, sessionId: item.session.id }
    return (
      <TabNavItem
        href={tabHref(tab())}
        server={item.server}
        session={item.session}
        preparing={false}
        orientation="vertical"
        compact={compact}
        projectLabel={projectLabel(item.project)}
        closable={tabs.store.some((value) => tabKey(value) === tabKey(tab()))}
        active={sessions().current === item.key}
        pinned={pins().has(item.key)}
        onTogglePin={
          ready()
            ? () =>
                setSaved("pins", (keys) =>
                  keys.includes(item.key) ? keys.filter((key) => key !== item.key) : [...keys, item.key],
                )
            : undefined
        }
        onNavigate={() => tabs.select(tabs.addSessionTab({ server: item.server, sessionId: item.session.id }))}
        onClose={() => {
          const index = tabs.store.findIndex((value) => tabKey(value) === tabKey(tab()))
          if (index !== -1) tabs.closeTab(index)
        }}
        onRename={async (title) => {
          const context = ctx()
          if (!context) return
          await context.sdk.api.session
            .rename({ sessionID: item.session.id, title })
            .then(() => {
              context.data.session.remember({ ...item.session, title })
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
  const section = (title: string, rows: SidebarSession[]) => (
    <Show when={rows.length}>
      <section class="mt-4 first:mt-0">
        <h2 class="mb-1 px-1.5 text-[13px] leading-4 text-v2-text-text-muted">{title}</h2>
        <div class="flex flex-col gap-1">
          <For each={rows}>{(item) => row(item)}</For>
        </div>
      </section>
    </Show>
  )
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
      <div class="shrink-0 pt-4 [app-region:no-drag]">
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
      <nav
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
              <For each={results()}>{(item) => row(item)}</For>
            </div>
          </div>
        </Show>
        <Show when={!query()}>
          <Show
            when={saved.attention}
            fallback={
              <>
                {section(language.t("sidebar.sessions.pinned"), pinned())}
                {section(language.t("sidebar.sessions.recent"), recent())}
                <div class="mt-4 flex flex-col gap-2">
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
                        arrayMove(
                          projects().map((project) => project.key),
                          source.initialIndex,
                          source.index,
                        ),
                      )
                    }}
                  >
                    <For each={projects()}>
                      {(project, index) => {
                        const rows = createMemo(() => sessions().rows.filter((row) => row.project === project.key))
                        const collapsed = () => saved.collapsed[project.key] ?? false
                        const visible = () =>
                          visibleSessions(
                            rows(),
                            collapsed() ? 0 : (state.limits[project.key] ?? 5),
                            sessions().current,
                          )
                        return (
                          <SortableProject id={project.key} index={index()}>
                            {(handle) => (
                              <>
                                <div class="group flex h-7 items-center gap-1 rounded-[6px] hover:bg-v2-background-bg-layer-02">
                                  <button
                                    ref={handle}
                                    class="flex h-7 min-w-0 flex-1 touch-none items-center gap-1.5 px-1.5 text-start text-[13px] leading-4 text-v2-text-text-muted"
                                    classList={{
                                      "cursor-grab": state.drag !== project.key,
                                      "cursor-grabbing": state.drag === project.key,
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
                                      move(project.key, index() + (event.key === "ArrowUp" ? -1 : 1))
                                    }}
                                    aria-expanded={!collapsed()}
                                    onClick={(event) => {
                                      if (event.detail > 0 && gesture.dragged) return
                                      setSaved("collapsed", project.key, !collapsed())
                                    }}
                                  >
                                    <Icon
                                      name={collapsed() ? "chevron-right" : "chevron-down"}
                                      size="small"
                                      class={collapsed() ? "rtl:rotate-180" : ""}
                                    />
                                    <span dir="auto" class="min-w-0 truncate" title={projectLabel(project.key)}>
                                      {projectLabel(project.key)}
                                    </span>
                                    <Show when={collapsed() && rows().some((row) => row.attention !== undefined)}>
                                      <span
                                        class="size-1.5 shrink-0 rounded-full bg-v2-icon-icon-accent"
                                        aria-label={language.t("sidebar.attention.pending")}
                                      />
                                    </Show>
                                  </button>
                                </div>
                                <div class="flex flex-col gap-1">
                                  <For each={visible()}>{(item) => row(item, true)}</For>
                                </div>
                                <Show when={!collapsed() && rows().length > visible().length}>
                                  <button
                                    class="h-7 px-1.5 text-[13px] leading-4 text-v2-text-text-muted hover:text-v2-text-text-base"
                                    onClick={() => setState("limits", project.key, (value = 5) => value + 5)}
                                  >
                                    {language.t("sidebar.sessions.more")}
                                  </button>
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
                  <For each={groups().priority}>{(item) => row(item)}</For>
                </div>
              </Show>
            </section>
            {section(language.t("sidebar.sessions.pinned"), groups().pinned)}
            <For each={groups().days}>
              {(day) =>
                section(
                  day.index === 0
                    ? language.t("sidebar.sessions.today")
                    : day.index === 1
                      ? language.t("sidebar.sessions.yesterday")
                      : new Intl.DateTimeFormat(language.intl(), {
                          weekday: "long",
                          month: "short",
                          day: "numeric",
                        }).format(day.start),
                  day.rows,
                )
              }
            </For>
            {section(language.t("sidebar.sessions.current"), groups().current)}
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
