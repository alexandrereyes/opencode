import { createEffect, createMemo, createResource, For, Show, on, onCleanup, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { A } from "@solidjs/router"
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
import { getFilename } from "@opencode/util/path"
import { SubagentContext } from "./subagent-context"

const SUBAGENT_PAGE_SIZE = 10

function Section(props: { title: string; count?: JSX.Element; children: JSX.Element }) {
  return (
    <details open class="group border-b border-border-weak-base pb-3">
      <summary class="flex min-h-8 cursor-pointer list-none items-center gap-2 rounded-sm text-14-medium text-text-strong focus-visible:outline-2 focus-visible:outline-border-active [&::-webkit-details-marker]:hidden">
        <Icon
          name="chevron-down"
          size="small"
          class="-rotate-90 group-open:rotate-0 rtl:rotate-90 rtl:group-open:rotate-0"
        />
        <span>{props.title}</span>
        <span class="ms-auto text-12-regular text-v2-text-text-muted tabular-nums">{props.count}</span>
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

export function ContextOverview(props: { tokens?: number; usage?: number | null; active: boolean }) {
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
  const [state, setState] = createStore({ subagentLimit: SUBAGENT_PAGE_SIZE })
  const familyRequest = createMemo(() => {
    const id = layout.params.id
    if (!props.active || !id) return
    const controller = new AbortController()
    onCleanup(() => controller.abort())
    return { id, signal: controller.signal }
  })
  const [family] = createResource(
    familyRequest,
    async (request) => {
      // Follow pagination and descendants instead of relying on the currently cached session page.
      const visit = async (parentID: string): Promise<void> => {
        const page = async (cursor?: string): Promise<void> => {
          if (request.signal.aborted) return
          const result = await sdk.api.session.list(cursor ? { cursor } : { parentID, limit: 100 })
          // Resource cancellation alone cannot protect writes to the shared session cache.
          if (request.signal.aborted) return
          result.data.forEach((session) => data.session.remember(session))
          await Promise.all(result.data.map((session) => visit(session.id)))
          if (result.cursor.next) await page(result.cursor.next)
        }
        await page()
      }
      return visit(request.id)
        .then(() => ({ id: request.id, ok: true }))
        .catch(() => ({ id: request.id, ok: false }))
    },
  )
  // `latest` falls back to the suspending resource read before its first result.
  // These optional sections must never enlist the enclosing route's Suspense.
  const familyResult = () =>
    family.state === "ready" || family.state === "refreshing" ? family.latest : undefined
  const familyPending = () => family.loading || !familyResult() || familyResult()?.id !== layout.params.id
  const familyFailed = () => !familyPending() && familyResult()?.ok === false
  const children = createMemo(() => {
    const id = layout.params.id
    const sessions = data.session.list()
    const descendants = (parentID: string): typeof sessions =>
      sessions
        .filter((session) => session.parentID === parentID)
        .flatMap((session) => [session, ...descendants(session.id)])
    return id ? descendants(id) : []
  })
  const visibleChildren = createMemo(() => children().slice(0, state.subagentLimit))
  const hasMoreChildren = () => children().length > visibleChildren().length
  createEffect(on(() => layout.params.id, () => setState("subagentLimit", SUBAGENT_PAGE_SIZE), { defer: true }))
  const money = (value: number) =>
    new Intl.NumberFormat(language.intl(), {
      style: "currency",
      currency: "USD",
      maximumFractionDigits: 4,
    }).format(value)
  const childCost = createMemo(() => children().reduce((total, session) => total + session.cost, 0))
  const project = createMemo(() => {
    const id = info()?.projectID
    return id ? data.project.get(id) : undefined
  })
  const projectName = createMemo(() => project()?.name || getFilename(project()?.canonical ?? directory()))
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
          <bdi dir="auto" class="min-w-0 max-w-[50%] truncate" title={projectName()}>
            {projectName()}
          </bdi>
          <Icon name="branch" size="small" class="shrink-0 text-v2-icon-icon-muted" />
          <bdi dir="auto" class="min-w-0 flex-1 truncate" title={branch()}>
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
        </div>
        <Meter value={props.usage ?? null} label={language.t("context.overview.context")} />
        <div class="flex flex-wrap items-baseline justify-between gap-2 text-12-regular text-v2-text-text-muted tabular-nums">
          <span>
            {language.t("context.overview.costs", {
              session: money(info()?.cost ?? 0),
              subagents: familyPending() || familyFailed() ? "—" : money(childCost()),
            })}
          </span>
          <span class="text-text-base">
            {familyPending() || familyFailed() ? "—" : money((info()?.cost ?? 0) + childCost())}
          </span>
        </div>
      </section>
      <Section
        title={language.t("context.overview.subagents")}
        count={familyPending() || familyFailed() ? "—" : children().length}
      >
        <Show when={familyPending()}>
          <Loading />
        </Show>
        <Show when={familyFailed()}>
          <p role="status">{language.t("context.overview.childrenFailed")}</p>
        </Show>
        <Show
          when={children().length}
          fallback={
            <Show when={!familyPending() && !familyFailed()}>
              <p class="text-v2-text-text-muted">{language.t("context.overview.noSubagents")}</p>
            </Show>
          }
        >
          <For each={visibleChildren()}>
            {(child) => (
              <A
                href={sessionHref(server.key, child.id)}
                class="flex min-h-9 min-w-0 items-center justify-between gap-3 rounded-md px-2 py-1 hover:bg-surface-raised-base focus-visible:outline-2 focus-visible:outline-border-active"
              >
                <span class="min-w-0 flex-1">
                  <bdi class="block truncate" title={child.title}>
                    <TextShimmer text={child.title ?? child.id} active={data.session.status(child.id) === "running"} />
                  </bdi>
                  <SubagentContext child={child} active={props.active} />
                </span>
                <span class="shrink-0 text-end text-12-regular text-v2-text-text-muted">
                  <span class="block">
                    {language.t(
                      data.session.status(child.id) === "running"
                        ? "context.overview.running"
                        : child.outcome
                          ? `context.overview.${child.outcome}`
                          : "context.overview.idle",
                    )}
                  </span>
                  <Show when={child.cost > 0}>
                    <span class="block tabular-nums">{money(child.cost)}</span>
                  </Show>
                </span>
              </A>
            )}
          </For>
          <Show when={hasMoreChildren() || visibleChildren().length > SUBAGENT_PAGE_SIZE}>
            <button
              type="button"
              class="ms-2 block h-7 w-fit max-w-full rounded-[6px] px-1.5 text-start text-13-regular text-v2-text-text-muted hover:text-v2-text-text-base focus-visible:outline-none focus-visible:bg-v2-background-bg-layer-02"
              onClick={() =>
                setState("subagentLimit", (limit) =>
                  hasMoreChildren() ? limit + SUBAGENT_PAGE_SIZE : SUBAGENT_PAGE_SIZE,
                )
              }
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
                <div class="flex min-h-9 min-w-0 items-center justify-between gap-3">
                  <span class="min-w-0">
                    <bdi class="block truncate">{item.name}</bdi>
                    <span class="text-12-regular text-v2-text-text-muted">
                      {language.t(`mcp.status.${item.status.status}`)}
                    </span>
                  </span>
                  <Switch
                    appearance="standard"
                    aria-label={item.name}
                    checked={item.status.status === "connected"}
                    disabled={toggleMcp.isPending || item.status.status === "pending"}
                    onChange={() => toggleMcp.mutate(item.name)}
                  />
                </div>
              )}
            </For>
          </Show>
        </Show>
      </Section>
    </div>
  )
}
