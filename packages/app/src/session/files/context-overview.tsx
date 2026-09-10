import { createEffect, createMemo, createResource, For, Show, onCleanup, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { A } from "@solidjs/router"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { Switch } from "@opencode/ui/switch"
import { Spinner } from "@opencode/ui/spinner"
import { TextShimmer } from "@opencode/ui/text-shimmer"
import { useDialog } from "@opencode/ui/context/dialog"
import { Dialog, DialogBody, DialogHeader, DialogTitle } from "@opencode/ui/dialog"
import { createSessionBackground } from "@/session/requests/background"
import { useData, useServer } from "@/runtime/server/current"
import { useServerSDK } from "@/runtime/server/client"
import { useLanguage } from "@/runtime/i18n/language"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useSessionLayout } from "@/session/session-layout"
import { useMcpToggle } from "@/providers/connect/mcp"
import { sessionHref } from "@/shell/routes/session"
import { getFilename } from "@opencode/util/path"
import { subscriptionCapacity, subscriptionPercentages, subscriptionPool } from "./subscription-pool"

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
  const [clock, setClock] = createStore({ now: Date.now() })
  const [subscriptions, quota] = createResource(
    () => props.active,
    () =>
      sdk.api.server.subscriptions().catch(() => ({
        status: "unavailable" as const,
        accounts: [],
      })),
  )
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
  const subscription = createMemo(() =>
    subscriptions.state === "ready" || subscriptions.state === "refreshing" ? subscriptions.latest : undefined,
  )
  const familyResult = () =>
    family.state === "ready" || family.state === "refreshing" ? family.latest : undefined
  const familyPending = () => family.loading || !familyResult() || familyResult()?.id !== layout.params.id
  const familyFailed = () => !familyPending() && familyResult()?.ok === false
  const pool = createMemo(() => subscriptionPool(subscription()?.accounts ?? [], clock.now))
  const updated = () => {
    const at = pool().observedAt
    if (at === null)
      return language.t("context.overview.measurements", { measured: pool().measured, total: pool().total })
    const minutes = Math.max(0, Math.floor((clock.now - at) / 60_000))
    return language.t("context.overview.updated", {
      time: new Intl.RelativeTimeFormat(language.intl(), { numeric: "auto" }).format(
        minutes >= 60 ? -Math.floor(minutes / 60) : -minutes,
        minutes >= 60 ? "hour" : "minute",
      ),
    })
  }
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
  const projectName = createMemo(() => project()?.name || getFilename(project()?.canonical ?? directory()))
  const branch = createMemo(() => data.location.vcs.info({ directory: directory() })?.branch.current ?? "—")
  const mcp = createMemo(() =>
    data.location.mcp.server.list({ directory: directory() })?.toSorted((a, b) => a.name.localeCompare(b.name)),
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
          <For each={children()}>
            {(child) => (
              <A
                href={sessionHref(server.key, child.id)}
                class="flex min-h-9 min-w-0 items-center justify-between gap-3 rounded-md px-2 py-1 hover:bg-surface-raised-base focus-visible:outline-2 focus-visible:outline-border-active"
              >
                <span class="min-w-0 flex-1">
                  <bdi class="block truncate" title={child.title}>
                    <TextShimmer text={child.title ?? child.id} active={data.session.status(child.id) === "running"} />
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
      </Section>
      <section class="flex min-w-0 flex-col gap-2 border-b border-border-weak-base pb-3">
        <div class="flex min-h-8 items-center justify-between gap-2">
          <h2 class="text-14-medium text-text-strong">{language.t("context.overview.subscriptions")}</h2>
          <IconButton
            icon={subscriptions.loading ? <Spinner class="size-3.5" /> : <Icon name="refresh" size="small" />}
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
        <Show when={subscription()} fallback={<Loading />}>
          <Show
            when={subscription()?.status === "ok"}
            fallback={
              <p class="text-v2-text-text-muted" role="status">
                {language.t(
                  subscription()?.status === "unconfigured"
                    ? "context.overview.unconfigured"
                    : "context.overview.unavailable",
                )}
              </p>
            }
          >
            <Show
              when={subscription()?.accounts.length}
              fallback={<p>{language.t("context.overview.noSubscriptions")}</p>}
            >
              <details class="group" data-slot="subscription-pool">
                <summary class="flex cursor-pointer list-none flex-col gap-2 rounded-sm focus-visible:outline-2 focus-visible:outline-border-active [&::-webkit-details-marker]:hidden">
                  <div class="flex flex-wrap items-center gap-2">
                    <Icon
                      name="chevron-down"
                      size="small"
                      class="-rotate-90 group-open:rotate-0 rtl:rotate-90 rtl:group-open:rotate-0"
                    />
                    <span class="text-13-medium text-text-strong">{language.t("context.overview.availablePool")}</span>
                    <span class="ms-auto text-end tabular-nums">
                      {pool().total === 0
                        ? language.t("context.overview.noPool")
                        : pool().balance === "unknown"
                          ? language.t("context.overview.unknownWeekly")
                          : pool().balance === "unavailable"
                            ? language.t("context.overview.noAvailableBalance")
                            : language.t("context.overview.availablePoolRemaining", {
                                percent: new Intl.NumberFormat(language.intl(), {
                                  style: "percent",
                                  maximumFractionDigits: 0,
                                }).format((pool().availableRemaining ?? 0) / 100),
                              })}
                    </span>
                  </div>
                  <Meter
                    value={pool().availableRemaining}
                    remaining
                    label={language.t("context.overview.availablePool")}
                  />
                  <div class="flex flex-wrap justify-between gap-x-3 gap-y-1 text-12-regular text-v2-text-text-muted">
                    <span>
                      {language.t("context.overview.availablePoolCapacity", {
                        ready: pool().ready,
                        total: pool().total,
                      })}
                    </span>
                    <span>{updated()}</span>
                  </div>
                  <Show when={pool().measured < pool().total && pool().observedAt !== null}>
                    <span class="text-12-regular text-v2-text-text-muted">
                      {language.t("context.overview.measurements", { measured: pool().measured, total: pool().total })}
                    </span>
                  </Show>
                  <div class="flex flex-col gap-1 border-t border-border-weak-base pt-2 text-12-regular text-v2-text-text-muted">
                    <div class="flex flex-wrap justify-between gap-2">
                      <span>{language.t("context.overview.banked")}</span>
                      <span class="tabular-nums">
                        {pool().banked?.available ?? language.t("context.overview.bankedUnknown")}
                      </span>
                    </div>
                    <Show when={pool().banked && (pool().banked?.available ?? 0) > 0}>
                      <div class="flex flex-wrap justify-between gap-x-3 gap-y-1">
                        <span>
                          {language.t("context.overview.expiryMin", {
                            date:
                              pool().banked?.earliest === null
                                ? language.t("context.overview.noExpiry")
                                : new Intl.DateTimeFormat(language.intl(), {
                                    dateStyle: "medium",
                                    timeStyle: "short",
                                  }).format(pool().banked?.earliest ?? 0),
                          })}
                        </span>
                        <span>
                          {language.t("context.overview.expiryMax", {
                            date:
                              (pool().banked?.nonExpiring ?? 0) > 0
                                ? language.t("context.overview.noExpiry")
                                : new Intl.DateTimeFormat(language.intl(), {
                                    dateStyle: "medium",
                                    timeStyle: "short",
                                  }).format(pool().banked?.latest ?? 0),
                          })}
                        </span>
                      </div>
                    </Show>
                  </div>
                </summary>
                <div class="mt-3 flex min-w-0 flex-col gap-2 border-t border-border-weak-base pt-2">
                  <p class="text-12-regular text-v2-text-text-muted">{language.t("context.overview.weekly")}</p>
                  <For each={subscription()?.accounts}>
                    {(account) => {
                      const capacity = () => subscriptionCapacity(account, clock.now)
                      const percentages = account.remaining === null ? null : subscriptionPercentages(account.remaining)
                      return (
                        <div role="group" aria-label={account.name} class="flex flex-col gap-1.5 py-1">
                          <div class="flex flex-wrap items-baseline justify-between gap-2">
                            <bdi class="min-w-0 break-all text-13-medium text-text-strong">{account.name}</bdi>
                            <bdi class="tabular-nums">
                              {percentages === null
                                ? language.t("context.overview.unknownWeekly")
                                : language.t("context.overview.accountUsage", {
                                    remaining: new Intl.NumberFormat(language.intl(), {
                                      style: "percent",
                                      maximumFractionDigits: 0,
                                    }).format(percentages.remaining / 100),
                                    used: new Intl.NumberFormat(language.intl(), {
                                      style: "percent",
                                      maximumFractionDigits: 0,
                                    }).format(percentages.used / 100),
                                  })}
                            </bdi>
                          </div>
                          <Meter value={account.remaining} remaining label={account.name} />
                          <div class="flex flex-wrap gap-1.5 text-12-regular text-v2-text-text-muted">
                            <span class="rounded-full bg-surface-raised-base px-2 py-0.5">
                              {account.plan
                                ? language.t("context.overview.plan", {
                                    plan:
                                      account.plan === "pro" ? "Pro" : account.plan === "plus" ? "Plus" : account.plan,
                                  })
                                : language.t("context.overview.planUnknown")}
                            </span>
                            <span class="rounded-full bg-surface-raised-base px-2 py-0.5">
                              {language.t(
                                capacity() === "outside"
                                  ? "context.overview.outsidePool"
                                  : capacity() === "unconfirmed"
                                    ? "context.overview.capacityUnconfirmed"
                                    : capacity() === "available"
                                      ? "context.overview.capacityAvailable"
                                      : "context.overview.capacityUnavailable",
                              )}
                            </span>
                          </div>
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
                          <p class="text-12-regular text-v2-text-text-muted">
                            {language.t(
                              !account.enabled
                                ? "context.overview.disabled"
                                : !account.authenticated
                                  ? "context.overview.reauthenticate"
                                  : account.cooldownSeconds > 0
                                    ? "context.overview.cooldown"
                                    : account.stale || capacity() === "unconfirmed"
                                      ? "context.overview.capacityUnconfirmed"
                                      : account.hasCapacity === false
                                        ? "context.overview.noCapacity"
                                        : account.plan !== "pro"
                                          ? "context.overview.outsidePool"
                                          : "context.overview.available",
                            )}
                          </p>
                        </div>
                      )
                    }}
                  </For>
                </div>
              </details>
            </Show>
          </Show>
        </Show>
      </section>
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
