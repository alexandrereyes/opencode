import { createEffect, createMemo, For, onCleanup, onMount, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { A } from "@solidjs/router"
import { Key } from "@solid-primitives/keyed"
import { Schema } from "effect"
import { Icon } from "@opencode/ui/icon"
import { useGlobal, type ServerCtx } from "@/runtime/server/runtime"
import { ServerConnection, serverName } from "@/runtime/server/registry"
import { useLanguage } from "@/runtime/i18n/language"
import { Persist, persisted } from "@/runtime/persistence/storage"
import { Persistence } from "@/runtime/persistence/schema"
import { useTabs } from "@/shell/tabs/tabs"
import { sessionHref } from "@/shell/routes/session"
import { createSidebarIndex } from "@/shell/titlebar/sidebar-index"
import { projectKey } from "@/shell/titlebar/sidebar-model"
import { dashboardFamily, dashboardStatus, dashboardWindow, filterDashboard, type DashboardRow } from "./model"
import { createDashboardPreview, createPreviewQueue } from "./preview"
import "./style.css"

const DashboardState = Persistence.struct({
  server: Schema.String,
  project: Schema.String,
  search: Schema.String,
  status: Schema.Literals(["recent", "all", "running", "attention", "completed", "error", "idle"]),
  density: Schema.Literals(["compact", "comfortable"]),
  children: Schema.Boolean,
  limit: Schema.Finite,
  scroll: Schema.Finite,
})

export function AgentDashboard() {
  const global = useGlobal()
  const language = useLanguage()
  const [saved, setSaved, , ready] = persisted(Persist.window("agent-dashboard"), DashboardState, {
    server: "",
    project: "",
    search: "",
    status: "recent",
    density: "compact",
    children: false,
    limit: 60,
    scroll: 0,
  })
  const [state, setState] = createStore({ now: Date.now(), restored: false })
  const enqueue = createPreviewQueue()
  const connection = createMemo(
    () => global.servers.list().find((conn) => ServerConnection.key(conn) === saved.server) ?? global.servers.list()[0],
  )
  const context = createMemo(() => {
    const conn = connection()
    if (!conn || !ready()) return
    const ctx = global.ensureServerCtx(conn)
    return { ctx, index: createSidebarIndex(ctx), key: ServerConnection.key(conn) }
  })
  const rows = createMemo(() => {
    const current = context()
    if (!current) return []
    return Object.values(current.index.state.rows).map((row): DashboardRow => {
      const session = current.ctx.data.session.get(row.session.id) ?? row.session
      const project = current.ctx.sync.data.project.find((project) => project.id === session.projectID)
      return {
        ...row,
        session,
        project: projectKey(current.key, { id: session.projectID, worktree: session.location.directory }),
        projectName:
          project?.name ??
          session.location.directory.split(/[\\/]/).filter(Boolean).at(-1) ??
          session.location.directory,
        branch: current.ctx.data.location.vcs.info(session.location)?.branch.current,
        status: dashboardStatus({ ...row, session }, current.ctx.data.session.status(session.id) === "running"),
        children: 0,
      }
    })
  })
  const projects = createMemo(() =>
    [...new Map(rows().map((row) => [row.project, row.projectName])).entries()].sort((a, b) =>
      a[1].localeCompare(b[1]),
    ),
  )
  const family = createMemo(() => dashboardFamily(rows(), saved.children))
  const filtered = createMemo(() => filterDashboard(family(), saved, state.now))
  const visible = createMemo(() => dashboardWindow(filtered(), saved.limit))
  const loading = () => !ready() || !context() || context()?.index.state.loading
  let viewport: HTMLDivElement | undefined
  const scroll = { top: 0 }
  const resetScroll = () => {
    setSaved({ scroll: 0, limit: 60 })
    scroll.top = 0
    if (viewport) viewport.scrollTop = 0
  }
  createEffect(() => {
    if (loading() || state.restored || !viewport) return
    const top = saved.scroll
    // Restore after the loading placeholder has been replaced by the card grid.
    const frame = requestAnimationFrame(() => {
      if (!viewport) return
      viewport.scrollTop = top
      scroll.top = viewport.scrollTop
      setState("restored", true)
    })
    onCleanup(() => cancelAnimationFrame(frame))
  })
  const timer = setInterval(() => setState("now", Date.now()), 60_000)
  onCleanup(() => {
    clearInterval(timer)
    if (ready() && state.restored) setSaved("scroll", scroll.top)
  })
  return (
    <div class="agent-dashboard" data-density={saved.density}>
      <header class="agent-dashboard-header">
        <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
          <h1 class="text-16-medium text-v2-text-text-base">{language.t("dashboard.title")}</h1>
          <Show when={global.servers.list().length > 1}>
            <select
              aria-label={language.t("dashboard.server")}
              class="agent-dashboard-control max-w-full"
              value={context()?.key ?? ""}
              onChange={(event) => {
                setSaved({ server: event.currentTarget.value, project: "" })
                resetScroll()
              }}
            >
              <For each={global.servers.list()}>
                {(conn) => <option value={ServerConnection.key(conn)}>{serverName(conn)}</option>}
              </For>
            </select>
          </Show>
        </div>
        <div class="agent-dashboard-filters">
          <input
            type="search"
            class="agent-dashboard-control agent-dashboard-search"
            aria-label={language.t("dashboard.search")}
            placeholder={language.t("dashboard.search")}
            value={saved.search}
            onInput={(event) => {
              setSaved("search", event.currentTarget.value)
              resetScroll()
            }}
          />
          <select
            class="agent-dashboard-control"
            aria-label={language.t("dashboard.project")}
            value={saved.project}
            onChange={(event) => {
              setSaved("project", event.currentTarget.value)
              resetScroll()
            }}
          >
            <option value="">{language.t("dashboard.projects.all")}</option>
            <For each={projects()}>{([key, name]) => <option value={key}>{name}</option>}</For>
          </select>
          <select
            class="agent-dashboard-control"
            aria-label={language.t("dashboard.filter")}
            value={saved.status}
            onChange={(event) => {
              setSaved("status", Schema.decodeUnknownSync(DashboardState.fields.status)(event.currentTarget.value))
              resetScroll()
            }}
          >
            <For each={["recent", "all", "running", "attention", "completed", "error", "idle"] as const}>
              {(status) => <option value={status}>{language.t(`dashboard.filter.${status}`)}</option>}
            </For>
          </select>
          <select
            class="agent-dashboard-control"
            aria-label={language.t("dashboard.density")}
            value={saved.density}
            onChange={(event) => {
              setSaved("density", event.currentTarget.value === "comfortable" ? "comfortable" : "compact")
              resetScroll()
            }}
          >
            <option value="compact">{language.t("dashboard.compact")}</option>
            <option value="comfortable">{language.t("dashboard.comfortable")}</option>
          </select>
          <label class="flex min-h-8 items-center gap-2 text-v2-text-text-muted">
            <input
              type="checkbox"
              checked={saved.children}
              onChange={(event) => {
                setSaved("children", event.currentTarget.checked)
                resetScroll()
              }}
            />
            {language.t("dashboard.children")}
          </label>
        </div>
        <div class="flex flex-wrap justify-between gap-x-4 gap-y-1 text-v2-text-text-muted">
          <p>{language.t(saved.status === "recent" ? "dashboard.window" : "dashboard.order")}</p>
          <span role="status">
            {language.plural("dashboard.count", filtered().length, { count: filtered().length })}
          </span>
        </div>
      </header>
      <div
        ref={viewport}
        class="agent-dashboard-viewport"
        data-slot="dashboard-scroll"
        onScroll={(event) => {
          scroll.top = event.currentTarget.scrollTop
        }}
      >
        <Show when={context()?.ctx.sdk.connection.status() !== "connected"}>
          <p class="agent-dashboard-notice" role="status">
            {language.t("dashboard.disconnected")}
          </p>
        </Show>
        <Show when={context()?.index.state.error}>
          <button
            type="button"
            class="agent-dashboard-notice agent-dashboard-retry"
            onClick={() => context()?.index.retry()}
          >
            {language.t("dashboard.retry")}
          </button>
        </Show>
        <Show
          when={!loading()}
          fallback={
            <p class="agent-dashboard-notice" role="status">
              {language.t("dashboard.loading")}
            </p>
          }
        >
          <Show
            when={filtered().length}
            fallback={
              <div class="agent-dashboard-empty">
                <h2 class="text-14-medium text-v2-text-text-base">{language.t("dashboard.empty")}</h2>
                <p>{language.t("dashboard.empty.hint")}</p>
                <button
                  class="agent-dashboard-control"
                  onClick={() => {
                    setSaved({ search: "", project: "", status: "all" })
                    resetScroll()
                  }}
                >
                  {language.t("dashboard.showAll")}
                </button>
              </div>
            }
          >
            <Show when={context()} keyed>
              {(current) => (
                <div class="agent-dashboard-grid">
                  <Key each={visible()} by={(row) => row.session.id}>
                    {(row) => <DashboardCard row={row()} ctx={current.ctx} server={current.key} enqueue={enqueue} />}
                  </Key>
                </div>
              )}
            </Show>
            <Show when={filtered().length > visible().length}>
              <div class="flex justify-center p-4">
                <button class="agent-dashboard-control" onClick={() => setSaved("limit", (limit) => limit + 60)}>
                  {language.t("dashboard.more")}
                </button>
              </div>
            </Show>
          </Show>
        </Show>
      </div>
    </div>
  )
}

function DashboardCard(props: {
  row: DashboardRow
  ctx: ServerCtx
  server: ServerConnection.Key
  enqueue: ReturnType<typeof createPreviewQueue>
}) {
  const language = useLanguage()
  const tabs = useTabs()
  const [state, setState] = createStore({ visible: false })
  let element: HTMLAnchorElement | undefined
  onMount(() => {
    const observer = new IntersectionObserver(
      (entries) =>
        setState(
          "visible",
          entries.some((entry) => entry.isIntersecting),
        ),
      { rootMargin: "160px" },
    )
    if (element) observer.observe(element)
    onCleanup(() => observer.disconnect())
  })
  const preview = createDashboardPreview({
    sdk: props.ctx.sdk,
    sessionID: props.row.session.id,
    visible: () => state.visible,
    enqueue: props.enqueue,
  })
  createEffect(() => {
    if (!state.visible || props.ctx.sdk.connection.status() !== "connected") return
    void props.ctx.data.location.vcs.sync(props.row.session.location).catch(() => undefined)
  })
  const updated = () =>
    Math.max(props.row.session.time.idle ?? 0, props.row.messageAt ?? props.row.session.time.created)
  return (
    <A
      ref={element}
      href={sessionHref(props.server, props.row.session.id)}
      class="agent-dashboard-card"
      data-status={props.row.status}
      aria-label={language.t("dashboard.open", { title: props.row.session.title ?? language.t("dashboard.untitled") })}
      onClick={(event) => {
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return
        event.preventDefault()
        props.ctx.data.session.remember(props.row.session)
        tabs.select(tabs.addSessionTab({ server: props.server, sessionId: props.row.session.id }))
      }}
    >
      <div class="flex min-w-0 items-center justify-between gap-2">
        <span class="agent-dashboard-status">
          <span aria-hidden="true" />
          {language.t(`dashboard.status.${props.row.status}`)}
        </span>
        <time
          class="shrink-0 text-v2-text-text-muted tabular-nums"
          dateTime={new Date(updated()).toISOString()}
          title={new Date(updated()).toLocaleString(language.intl())}
        >
          {new Date(updated()).toLocaleString(language.intl(), {
            month: "short",
            day: "numeric",
            hour: "2-digit",
            minute: "2-digit",
          })}
        </time>
      </div>
      <h2 class="agent-dashboard-card-title" dir="auto" title={props.row.session.title}>
        {props.row.session.title ?? language.t("dashboard.untitled")}
      </h2>
      <div
        class="flex min-w-0 items-center gap-1.5 text-v2-text-text-muted"
        title={props.row.session.location.directory}
      >
        <Icon name="folder" size="small" class="shrink-0" />
        <bdi class="truncate">{props.row.projectName}</bdi>
        <Show when={props.row.branch}>
          <Icon name="branch" size="small" class="shrink-0" />
          <bdi class="truncate">{props.row.branch}</bdi>
        </Show>
      </div>
      <p class="agent-dashboard-directory" dir="ltr" title={props.row.session.location.directory}>
        {props.row.session.location.directory}
      </p>
      <p class="agent-dashboard-preview" dir="auto">
        {preview.text ||
          language.t(
            preview.error
              ? "dashboard.preview.error"
              : preview.loading
                ? "dashboard.preview.loading"
                : "dashboard.preview.empty",
          )}
      </p>
      <div class="agent-dashboard-card-footer">
        <span class="truncate" title={props.row.session.model?.id}>
          <bdi>{props.row.session.agent ?? language.t("dashboard.agent.unknown")}</bdi>
          <Show when={props.row.session.model}>
            <span aria-hidden="true"> · </span>
            <bdi>{props.row.session.model?.id}</bdi>
          </Show>
        </span>
        <Show when={props.row.status === "running" && preview.tool}>
          <span class="truncate" title={preview.tool}>
            {language.t("dashboard.tool", { tool: preview.tool ?? "" })}
          </span>
        </Show>
        <Show when={props.row.children > 0}>
          <span>{language.plural("dashboard.childCount", props.row.children, { count: props.row.children })}</span>
        </Show>
        <Show when={props.row.session.parentID}>
          <span>{language.t("dashboard.child")}</span>
        </Show>
      </div>
    </A>
  )
}
