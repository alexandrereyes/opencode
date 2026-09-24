import { createEffect, createMemo, For, on, Show, type JSX } from "solid-js"
import { A } from "@solidjs/router"
import { useQuery } from "@tanstack/solid-query"
import { Directories } from "@opencode/plugin-app-custom/directories/rpc"
import { Icon } from "@opencode/ui-custom/icon"
import { ProgressCircle } from "@opencode/ui-custom/progress-circle"
import { Switch } from "@opencode/ui-custom/switch"
import { Spinner } from "@opencode/ui-custom/spinner"
import { TextShimmer } from "@opencode/ui-custom/text-shimmer"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { Dialog, DialogBody, DialogHeader, DialogTitle } from "@opencode/ui-custom/dialog"
import { createSessionBackground } from "@/session/requests/background"
import { useData, useServer } from "@/runtime/server/current"
import { useServerSDK } from "@/runtime/server/client"
import { useLanguage } from "@/runtime/i18n/language"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useSessionLayout } from "@/session/session-layout"
import { useMcpToggle } from "@/providers/connect/mcp"
import { sessionHref } from "@/shell/routes/session"
import { createSubagentList } from "./subagent-list"
import { SUBAGENT_PAGE_SIZE } from "@/session/family"
import { SubagentContext } from "./subagent-context"

function Section(props: {
  title: string
  count?: JSX.Element
  children: JSX.Element
  open?: boolean
  onToggle?: (open: boolean) => void
}) {
  return (
    <details
      open={props.open ?? true}
      onToggle={(event) => props.onToggle?.(event.currentTarget.open)}
      class="group border-b border-border-weak-base pb-3"
    >
      <summary class="flex min-h-8 cursor-pointer list-none items-center gap-2 rounded-sm text-14-medium text-text-strong focus-visible:outline-2 focus-visible:outline-border-active [&::-webkit-details-marker]:hidden">
        <Icon
          name="chevron-down"
          size="small"
          class="-rotate-90 group-open:rotate-0 rtl:rotate-90 rtl:group-open:rotate-0"
        />
        <span>{props.title}</span>
        <span class="text-12-regular text-v2-text-text-muted tabular-nums">{props.count}</span>
      </summary>
      <div class="mt-1 flex min-w-0 flex-col gap-2">{props.children}</div>
    </details>
  )
}

function Meter(props: { value: number | null; label: string }) {
  const critical = () => props.value !== null && props.value >= 90
  const warning = () => props.value !== null && props.value >= 70
  return (
    <div
      role="meter"
      aria-label={props.label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={props.value ?? undefined}
      class="h-1.5 w-full overflow-hidden rounded-full bg-surface-raised-base"
    >
      <div
        class="h-full rounded-full"
        classList={{
          "bg-icon-critical-base": critical(),
          "bg-icon-warning-base": !critical() && warning(),
          "bg-icon-success-base": !critical() && !warning(),
        }}
        style={{ width: `${Math.max(0, Math.min(100, props.value ?? 0))}%` }}
      />
    </div>
  )
}

function Loading() {
  const language = useLanguage()
  return (
    <p role="status" class="flex items-center gap-2 text-v2-text-text-muted">
      <Spinner class="size-3.5" />
      {language.t("common.loading")}
    </p>
  )
}

export function ContextOverview(props: {
  tokens?: number
  usage?: number | null
  cacheHit?: number | null
  active: boolean
}) {
  const language = useLanguage()
  const dialog = useDialog()
  const data = useData()
  const server = useServer()
  const sdk = useServerSDK()
  const location = useWorkspaceLocation()
  const layout = useSessionLayout()
  const info = createMemo(() => (layout.params.id ? data.session.get(layout.params.id) : undefined))
  const directory = () => info()?.location.directory ?? location().directory
  const toggleMcp = useMcpToggle(directory)
  const background = createSessionBackground({
    sessionID: () => layout.params.id,
    messages: data.session.message.list,
    sessions: data.session.list,
    status: data.session.status,
    shells: () => (layout.params.id ? data.shell.listBySession(layout.params.id) : []),
  })
  const families = server.ctx.families
  families.watch(() => (props.active ? layout.params.id : undefined))
  const subagents = createSubagentList({
    sessionID: () => layout.params.id,
    active: () => props.active,
    version: (id) => families.get(id)?.version,
    page: families.page,
  })
  const snapshot = () => families.get(layout.params.id)?.snapshot
  const familyPending = () => !snapshot()
  const familyFailed = () => families.get(layout.params.id)?.failed
  const children = () => subagents.state.children
  const visibleChildren = createMemo(() => children().slice(0, subagents.state.subagentLimit))
  const hasMoreChildren = () => !!subagents.state.next || children().length > visibleChildren().length
  // Context limits need each child's model list; sync once per distinct location, not per row.
  const directories = createMemo(() =>
    props.active && subagents.state.open && sdk.connection.status() === "connected"
      ? [...new Set(visibleChildren().map((child) => child.location.directory))]
      : [],
  )
  createEffect(
    on(directories, (current, previous = []) =>
      current
        .filter((directory) => !previous.includes(directory))
        .forEach((directory) => void data.location.model.sync({ directory }).catch(() => undefined)),
    ),
  )
  const money = (value: number) =>
    new Intl.NumberFormat(language.intl(), {
      style: "currency",
      currency: "USD",
      maximumFractionDigits: 4,
    }).format(value)
  const childCost = () => snapshot()?.cost ?? 0
  // V2 sync does not publish the home directory, so the custom plugin reports it when available.
  const home = useQuery(() => ({
    queryKey: [sdk.scope, "custom-directories-home"],
    enabled: sdk.connection.status() === "connected",
    staleTime: Infinity,
    retry: false,
    queryFn: () =>
      sdk.api
        .rpc(Directories.Definition)
        .home({}, { location: { directory: directory() } })
        .then((result) => result.path.replace(/[\\/]+$/, "")),
  }))
  const displayDirectory = createMemo(() => {
    const root = home.data
    if (!root) return directory()
    if (directory() === root) return "~"
    return /^[\\/]/.test(directory().slice(root.length)) && directory().startsWith(root)
      ? `~${directory().slice(root.length)}`
      : directory()
  })
  const branch = createMemo(() => data.location.vcs.info({ directory: directory() })?.branch.current ?? "—")
  const mcp = createMemo(() =>
    data.location.mcp.server.list({ directory: directory() })?.toSorted((a, b) => a.name.localeCompare(b.name)),
  )

  return (
    <div data-slot="context-overview" class="flex min-w-0 flex-col gap-3 text-13-regular text-text-base">
      <section
        class="flex min-w-0 flex-col gap-2 border-b border-border-weak-base pb-3"
        aria-label={language.t("context.overview.session")}
      >
        <h2 class="flex min-w-0 items-center gap-2 text-14-medium text-text-strong">
          {/* Mobile already shows the session title in the header. */}
          <Show when={info()?.title}>
            {(title) => (
              <>
                <bdi dir="auto" class="hidden min-w-0 max-w-[40%] truncate md:block" title={title()}>
                  {title()}
                </bdi>
                <span aria-hidden="true" class="hidden shrink-0 text-v2-text-text-muted md:inline">
                  ·
                </span>
              </>
            )}
          </Show>
          <bdi dir="ltr" class="min-w-0 truncate" title={directory()}>
            {displayDirectory()}
          </bdi>
          <Icon name="branch" size="small" class="shrink-0 text-v2-icon-icon-muted" />
          <bdi dir="auto" class="min-w-0 max-w-[40%] shrink-0 truncate" title={branch()}>
            {branch()}
          </bdi>
        </h2>
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <span>{language.t("context.overview.context")}</span>
          <span class="inline-flex items-center gap-1.5">
            <Show when={props.usage != null}>
              <ProgressCircle
                appearance="indicator"
                size={16}
                strokeWidth={2}
                percentage={props.usage ?? 0}
                class="shrink-0"
                style={{
                  "--progress-circle-background": "var(--v2-background-bg-layer-04, var(--border-weak-base))",
                  "--progress-circle-background-overlay": "var(--v2-overlay-simple-overlay-pressed, transparent)",
                  "--progress-circle-progress": "var(--v2-icon-icon-base, var(--icon-base))",
                }}
              />
            </Show>
            <bdi class="tabular-nums">
              {props.tokens === undefined
                ? "—"
                : new Intl.NumberFormat(language.intl(), {
                    maximumFractionDigits: props.tokens >= 1000 ? 1 : 0,
                    useGrouping: false,
                  }).format(props.tokens >= 1000 ? props.tokens / 1000 : props.tokens)}
              {props.tokens !== undefined && props.tokens >= 1000 ? "K" : ""}
              {props.usage != null ? ` (${props.usage}%)` : ""}
            </bdi>
          </span>
          <Show when={props.cacheHit != null}>
            <span aria-hidden="true" class="text-v2-text-text-muted">
              ·
            </span>
            <span class="text-v2-text-text-muted tabular-nums">
              {language.t("context.overview.cacheHit", {
                percent: new Intl.NumberFormat(language.intl(), {
                  style: "percent",
                  maximumFractionDigits: 1,
                }).format(props.cacheHit ?? 0),
              })}
            </span>
          </Show>
        </div>
        <Meter value={props.usage ?? null} label={language.t("context.overview.context")} />
        <div class="flex flex-wrap items-baseline gap-x-1 gap-y-2 text-12-regular text-v2-text-text-muted tabular-nums">
          <span>
            {language.t("context.overview.costs", {
              session: money(info()?.cost ?? 0),
              subagents: familyPending() || familyFailed() ? "—" : money(childCost()),
            })}
          </span>
          <span aria-hidden="true">·</span>
          <span class="text-text-base">
            {language.t("context.overview.total", {
              cost: familyPending() || familyFailed() ? "—" : money((info()?.cost ?? 0) + childCost()),
            })}
          </span>
        </div>
      </section>
      <Section
        title={language.t("context.overview.subagents")}
        count={snapshot()?.count ?? "—"}
        open={subagents.state.open}
        onToggle={(open) => subagents.setState("open", open)}
      >
        <Show when={subagents.state.loading}>
          <Loading />
        </Show>
        <Show when={subagents.state.failed}>
          <p role="status">
            {language.t("context.overview.childrenFailed")}{" "}
            <button type="button" class="underline" onClick={() => void subagents.load()}>
              {language.t("common.retry")}
            </button>
          </p>
        </Show>
        <Show
          when={children().length}
          fallback={
            <Show when={subagents.state.loaded && !subagents.state.loading && !subagents.state.failed}>
              <p class="text-v2-text-text-muted">{language.t("context.overview.noSubagents")}</p>
            </Show>
          }
        >
          <For each={visibleChildren()}>
            {(child) => {
              const live = createMemo(() => ({ ...child, ...data.session.get(child.id) }))
              return (
                <A
                  href={sessionHref(server.key, child.id)}
                  class="flex min-h-9 min-w-0 flex-col justify-center rounded-md px-2 py-1 hover:bg-surface-raised-base focus-visible:outline-2 focus-visible:outline-border-active"
                >
                  <span class="flex min-w-0 items-baseline gap-1.5">
                    <bdi class="min-w-0 truncate" title={live().title}>
                      <TextShimmer
                        text={live().title ?? child.id}
                        active={data.session.status(child.id) === "running"}
                      />
                    </bdi>
                    <span aria-hidden="true" class="shrink-0 text-v2-text-text-muted">
                      ·
                    </span>
                    <span class="shrink-0 text-12-medium text-text-strong">
                      {language.t(
                        data.session.status(child.id) === "running"
                          ? "context.overview.running"
                          : live().outcome
                            ? `context.overview.${live().outcome!}`
                            : "context.overview.idle",
                      )}
                    </span>
                  </span>
                  <SubagentContext child={live()} cost={live().cost > 0 ? money(live().cost) : undefined} />
                </A>
              )
            }}
          </For>
          <Show when={hasMoreChildren() || visibleChildren().length > SUBAGENT_PAGE_SIZE}>
            <button
              type="button"
              class="ms-2 block h-7 w-fit max-w-full rounded-[6px] px-1.5 text-start text-13-regular text-v2-text-text-muted hover:text-v2-text-text-base focus-visible:outline-none focus-visible:bg-v2-background-bg-layer-02"
              disabled={subagents.state.loading}
              onClick={() => {
                if (children().length > subagents.state.subagentLimit) {
                  subagents.setState("subagentLimit", subagents.state.subagentLimit + SUBAGENT_PAGE_SIZE)
                  return
                }
                if (subagents.state.next) {
                  void subagents.load(true)
                  return
                }
                subagents.setState("subagentLimit", SUBAGENT_PAGE_SIZE)
              }}
            >
              {language.t(hasMoreChildren() ? "context.overview.subagents.more" : "context.overview.subagents.fewer")}
            </button>
          </Show>
        </Show>
      </Section>
      <Section title={language.t("context.overview.background")} count={background.tasks().length}>
        <Show
          when={background.tasks().length}
          fallback={<p class="text-v2-text-text-muted">{language.t("context.overview.noBackground")}</p>}
        >
          <ul class="flex min-w-0 flex-col gap-1" aria-label={language.t("context.overview.background")}>
            <For each={background.tasks()}>
              {(task) => (
                <li class="min-w-0">
                  <button
                    type="button"
                    class="flex h-8 w-full min-w-0 items-center gap-2 rounded-md px-2 text-start hover:bg-surface-raised-base focus-visible:outline-2 focus-visible:outline-border-active"
                    onClick={() =>
                      dialog.show(() => (
                        <Dialog>
                          <DialogHeader>
                            <DialogTitle>{language.t("context.overview.backgroundTask")}</DialogTitle>
                          </DialogHeader>
                          <DialogBody>
                            <div class="flex min-h-0 flex-col gap-3 px-4 pb-4">
                              <pre class="max-h-[60vh] overflow-auto whitespace-pre-wrap break-words text-13-regular text-text-strong [overflow-wrap:anywhere]">
                                {task.label}
                              </pre>
                              <Show when={task.type === "subagent"}>
                                <A
                                  class="text-13-medium text-text-strong underline"
                                  href={sessionHref(server.key, task.id)}
                                  onClick={() => dialog.close()}
                                >
                                  {language.t("context.overview.openSubagent")}
                                </A>
                              </Show>
                            </div>
                          </DialogBody>
                        </Dialog>
                      ))
                    }
                  >
                    <Icon
                      name={task.type === "shell" ? "console" : "subagent"}
                      size="small"
                      class="mt-0.5 shrink-0 text-v2-text-text-muted"
                    />
                    <span class="min-w-0 flex-1 truncate">
                      <TextShimmer
                        text={task.label.replace(/\s+/g, " ").trim()}
                        active
                        class="max-w-full [&_[data-slot=text-shimmer-char]]:min-w-0 [&_[data-slot=text-shimmer-char-base]]:truncate [&_[data-slot=text-shimmer-char-shimmer]]:truncate"
                      />
                    </span>
                    <span class="shrink-0 text-12-regular text-v2-text-text-muted">
                      {language.t(task.type === "shell" ? "ui.tool.shell" : "ui.tool.agent.default")}
                    </span>
                  </button>
                </li>
              )}
            </For>
          </ul>
        </Show>
      </Section>
      <Section
        title={language.t("status.popover.tab.mcp")}
        count={mcp() ? `${mcp()?.filter((item) => item.status.status === "connected").length}/${mcp()?.length}` : "—"}
      >
        <Show when={mcp()} fallback={<Loading />}>
          <Show when={mcp()?.length} fallback={<p class="text-v2-text-text-muted">{language.t("dialog.mcp.empty")}</p>}>
            <For each={mcp()}>
              {(item) => (
                <div class="flex min-h-9 min-w-0 items-center gap-3">
                  <Switch
                    appearance="standard"
                    aria-label={item.name}
                    class="shrink-0"
                    checked={item.status.status === "connected"}
                    disabled={toggleMcp.isPending || item.status.status === "pending"}
                    onChange={() => toggleMcp.mutate(item.name)}
                  />
                  <span class="min-w-0">
                    <bdi class="block truncate">{item.name}</bdi>
                    <span class="text-12-regular text-v2-text-text-muted">
                      {language.t(`mcp.status.${item.status.status}`)}
                    </span>
                  </span>
                </div>
              )}
            </For>
          </Show>
        </Show>
      </Section>
    </div>
  )
}
