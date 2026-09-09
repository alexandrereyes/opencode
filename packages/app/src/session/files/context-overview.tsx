import { createEffect, createMemo, createResource, For, Show, onCleanup, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { Dynamic } from "solid-js/web"
import { A } from "@solidjs/router"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { Switch } from "@opencode/ui/switch"
import { TextShimmer } from "@opencode/ui/text-shimmer"
import { createSessionBackground } from "@/session/requests/background"
import { useData, useServer } from "@/runtime/server/current"
import { useServerSDK } from "@/runtime/server/client"
import { useLanguage } from "@/runtime/i18n/language"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useSessionLayout } from "@/session/session-layout"
import { useMcpToggle } from "@/providers/connect/mcp"
import { sessionHref } from "@/shell/routes/session"
import { getFilename } from "@opencode/util/path"

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

function Meter(props: { value: number | null; label: string; remaining?: boolean }) {
  const critical = () => props.value !== null && (props.remaining ? props.value < 10 : props.value >= 90)
  const warning = () => props.value !== null && (props.remaining ? props.value < 30 : props.value >= 70)
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

export function ContextOverview(props: { tokens?: number; usage?: number | null; active: boolean }) {
  const language = useLanguage()
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
    shells: () => data.shell.list({ directory: directory() }),
  })
  const [clock, setClock] = createStore({ now: Date.now() })
  const [subscriptions, quota] = createResource(
    () => props.active,
    () =>
      sdk.api.server.subscriptions().catch(() => ({
        status: "unavailable" as const,
        accounts: [],
      })),
  )
  const [family] = createResource(
    () => props.active && layout.params.id,
    async (id) => {
      // Follow pagination and descendants instead of relying on the currently cached session page.
      const visit = async (parentID: string): Promise<void> => {
        const page = async (cursor?: string): Promise<void> => {
          const result = await sdk.api.session.list(cursor ? { cursor } : { parentID, limit: 100 })
          result.data.forEach((session) => data.session.remember(session))
          await Promise.all(result.data.map((session) => visit(session.id)))
          if (result.cursor.next) await page(result.cursor.next)
        }
        await page()
      }
      return visit(id)
        .then(() => true)
        .catch(() => false)
    },
  )
  const children = createMemo(() => {
    const id = layout.params.id
    const sessions = data.session.list()
    const descendants = (parentID: string): typeof sessions =>
      sessions
        .filter((session) => session.parentID === parentID)
        .flatMap((session) => [session, ...descendants(session.id)])
    return id ? descendants(id) : []
  })
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
  const mcp = createMemo(() =>
    (data.location.mcp.server.list({ directory: directory() }) ?? []).toSorted((a, b) => a.name.localeCompare(b.name)),
  )
  const resetTime = (value: string) => {
    const minutes = Math.ceil((Date.parse(value) - clock.now) / 60_000)
    if (minutes <= 0) return language.t("context.overview.resetPending")
    return new Intl.RelativeTimeFormat(language.intl(), { numeric: "always" }).format(
      minutes >= 1440 ? Math.ceil(minutes / 1440) : minutes >= 60 ? Math.ceil(minutes / 60) : minutes,
      minutes >= 1440 ? "day" : minutes >= 60 ? "hour" : "minute",
    )
  }
  createEffect(() => {
    if (!props.active) return
    const timer = setInterval(() => {
      if (document.hidden) return
      setClock("now", Date.now())
      void quota.refetch()
    }, 60_000)
    onCleanup(() => clearInterval(timer))
  })

  return (
    <div data-slot="context-overview" class="flex min-w-0 flex-col gap-3 text-13-regular text-text-base">
      <div class="grid min-w-0 grid-cols-1 gap-3 border-b border-border-weak-base pb-3 @[32rem]:grid-cols-2 @[32rem]:gap-6">
        <section class="flex min-w-0 flex-col gap-2" aria-label={language.t("context.overview.session")}>
          <h2 class="text-14-medium text-text-strong">{language.t("context.overview.session")}</h2>
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <span>{language.t("context.overview.context")}</span>
            <bdi class="tabular-nums">
              {props.tokens === undefined
                ? "—"
                : new Intl.NumberFormat(language.intl(), { notation: "compact", maximumFractionDigits: 1 }).format(
                    props.tokens,
                  )}
              {props.usage != null ? ` (${props.usage}%)` : ""}
            </bdi>
          </div>
          <Meter value={props.usage ?? null} label={language.t("context.overview.context")} />
          <div class="flex flex-wrap items-baseline justify-between gap-2 text-12-regular text-v2-text-text-muted tabular-nums">
            <span>
              {language.t("context.overview.costs", {
                session: money(info()?.cost ?? 0),
                subagents: money(childCost()),
              })}
            </span>
            <span class="text-text-base">{money((info()?.cost ?? 0) + childCost())}</span>
          </div>
        </section>
        <section class="flex min-w-0 flex-col gap-2">
          <div class="flex flex-wrap justify-between gap-2">
            <h2 class="text-14-medium text-text-strong">{language.t("context.overview.project")}</h2>
            <bdi class="min-w-0 break-words">{project()?.name || getFilename(project()?.canonical ?? directory())}</bdi>
          </div>
          <div class="flex min-w-0 items-center gap-2 text-v2-text-text-muted">
            <Icon name="branch" size="small" />
            <bdi class="min-w-0 break-all">
              {data.location.vcs.info({ directory: directory() })?.branch.current ?? "—"}
            </bdi>
          </div>
        </section>
      </div>
      <Section title={language.t("context.overview.subscriptions")} count={language.t("context.overview.remaining")}>
        <div class="flex items-center justify-between gap-2 text-12-regular text-v2-text-text-muted">
          <span>{language.t("context.overview.weekly")}</span>
          <IconButton
            icon={<Icon name="refresh" size="small" />}
            variant="ghost"
            size="small"
            disabled={subscriptions.loading}
            aria-label={language.t("context.overview.refresh")}
            onClick={() => {
              setClock("now", Date.now())
              void quota.refetch()
            }}
          />
        </div>
        <Show when={!subscriptions.loading || subscriptions.latest} fallback={<p>{language.t("common.loading")}</p>}>
          <Show
            when={subscriptions.latest?.status === "ok"}
            fallback={
              <p class="text-v2-text-text-muted" role="status">
                {language.t(
                  subscriptions.latest?.status === "unconfigured"
                    ? "context.overview.unconfigured"
                    : "context.overview.unavailable",
                )}
              </p>
            }
          >
            <Show
              when={subscriptions.latest?.accounts.length}
              fallback={<p>{language.t("context.overview.noSubscriptions")}</p>}
            >
              <For each={subscriptions.latest?.accounts}>
                {(account) => (
                  <div class="flex flex-col gap-1.5 py-1">
                    <div class="flex flex-wrap items-baseline justify-between gap-2">
                      <bdi class="min-w-0 break-all text-13-medium text-text-strong">{account.name}</bdi>
                      <bdi class="tabular-nums">{account.remaining === null ? "—" : `${account.remaining}%`}</bdi>
                    </div>
                    <Meter value={account.remaining} remaining label={account.name} />
                    <Show when={account.resetAt}>
                      {(reset) => (
                        <div class="flex flex-wrap justify-between gap-x-3 gap-y-1 text-12-regular text-v2-text-text-muted">
                          <time dir="auto" dateTime={reset()}>
                            {new Intl.DateTimeFormat(language.intl(), {
                              dateStyle: "medium",
                              timeStyle: "short",
                            }).format(new Date(reset()))}
                          </time>
                          <span>{resetTime(reset())}</span>
                        </div>
                      )}
                    </Show>
                    <Show when={account.stale || !account.enabled || account.hasCapacity === false}>
                      <p class="text-12-regular text-v2-text-text-muted">
                        {language.t(
                          !account.enabled
                            ? "context.overview.disabled"
                            : account.stale
                              ? "context.overview.stale"
                              : "context.overview.noCapacity",
                        )}
                      </p>
                    </Show>
                  </div>
                )}
              </For>
            </Show>
          </Show>
        </Show>
      </Section>
      <Section title={language.t("context.overview.subagents")} count={children().length}>
        <Show
          when={family.latest !== false}
          fallback={<p role="status">{language.t("context.overview.childrenFailed")}</p>}
        >
          <Show
            when={children().length}
            fallback={
              <p class="text-v2-text-text-muted">
                {language.t(family.loading ? "common.loading" : "context.overview.noSubagents")}
              </p>
            }
          >
            <For each={children()}>
              {(child) => (
                <A
                  href={sessionHref(server.key, child.id)}
                  class="flex min-h-9 min-w-0 items-center justify-between gap-3 rounded-md px-2 py-1 hover:bg-surface-raised-base focus-visible:outline-2 focus-visible:outline-border-active"
                >
                  <span class="min-w-0 flex-1">
                    <bdi class="block truncate" title={child.title}>
                      <TextShimmer
                        text={child.title ?? child.id}
                        active={data.session.status(child.id) === "running"}
                      />
                    </bdi>
                    <bdi class="block truncate text-12-regular text-v2-text-text-muted">{child.agent}</bdi>
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
                  <Dynamic
                    component={task.type === "subagent" ? A : "div"}
                    href={task.type === "subagent" ? sessionHref(server.key, task.id) : undefined}
                    class="flex min-h-7 min-w-0 items-start gap-2 rounded-md px-2 py-1"
                    classList={{
                      "hover:bg-surface-raised-base focus-visible:outline-2 focus-visible:outline-border-active":
                        task.type === "subagent",
                    }}
                  >
                    <Icon
                      name={task.type === "shell" ? "console" : "subagent"}
                      size="small"
                      class="mt-0.5 shrink-0 text-v2-text-text-muted"
                    />
                    <span class="min-w-0 flex-1 break-words">
                      <TextShimmer
                        text={task.label}
                        active
                        class="w-full [&_[data-slot]]:min-w-0 [&_[data-slot]]:whitespace-pre-wrap! [&_[data-slot]]:[overflow-wrap:anywhere]!"
                      />
                    </span>
                    <span class="shrink-0 text-12-regular text-v2-text-text-muted">
                      {language.t(task.type === "shell" ? "ui.tool.shell" : "ui.tool.agent.default")}
                    </span>
                  </Dynamic>
                </li>
              )}
            </For>
          </ul>
        </Show>
      </Section>
      <Section
        title={language.t("status.popover.tab.mcp")}
        count={`${mcp().filter((item) => item.status.status === "connected").length}/${mcp().length}`}
      >
        <Show when={mcp().length} fallback={<p class="text-v2-text-text-muted">{language.t("dialog.mcp.empty")}</p>}>
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
      </Section>
    </div>
  )
}
