import { createEffect, createMemo, createResource, For, onCleanup, Show, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { Popover } from "@opencode/ui-custom/popover"
import { Spinner } from "@opencode/ui-custom/spinner"
import { Subscriptions } from "@opencode/plugin-app-custom/subscriptions/rpc"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection } from "@/runtime/server/registry"
import { useLanguage } from "@/runtime/i18n/language"
import type { Tab } from "@/shell/tabs/tabs"
import { subscriptionAccounts, subscriptionCapacity, subscriptionPool } from "@/session/files/subscription-pool"

export function SidebarSubscriptions(props: { currentTab?: Tab; mobile?: boolean; onOpenChange?: (open: boolean) => void }) {
  const global = useGlobal()
  const language = useLanguage()
  const [state, setState] = createStore({ open: false, now: Date.now() })
  const source = createMemo(
    () => {
      const tab = props.currentTab
      const connection =
        global.servers.list().find((item) => ServerConnection.key(item) === tab?.server) ??
        global.settings.server.selected()
      if (!connection) return
      const ctx = global.ensureServerCtx(connection)
      const directory =
        tab?.type === "draft"
          ? tab.directory
          : tab?.type === "session"
            ? ctx.data.session.get(tab.routeSessionId ?? tab.sessionId)?.location.directory
            : undefined
      return { ctx, directory: directory ?? ctx.projects.list()[0]?.worktree ?? "" }
    },
    undefined,
    { equals: (a, b) => a?.ctx === b?.ctx && a?.directory === b?.directory },
  )
  const [resource, actions] = createResource(source, async (source) => ({
    source,
    data: await source.ctx.sdk.api
      .rpc(Subscriptions.Definition)
      .list({}, { location: { directory: source.directory } })
      .catch(() => ({ status: "unavailable" as const, accounts: [] })),
  }))
  // An optional status must not suspend the shell while its first request is pending.
  const subscription = () => {
    const result = resource.state === "ready" || resource.state === "refreshing" ? resource.latest : undefined
    return result && result.source === source() ? result.data : undefined
  }
  const pool = createMemo(() => subscriptionPool(subscription()?.accounts ?? [], state.now))
  const accounts = createMemo(() => subscriptionAccounts(subscription()?.accounts ?? [], state.now))
  const nextRenewal = createMemo(() => {
    const resets = accounts().flatMap((account) =>
      account.plan === "pro" && account.enabled && account.authenticated && account.resetAt
        ? [Date.parse(account.resetAt)]
        : [],
    )
    return resets.length ? Math.max(0, Math.ceil((Math.min(...resets) - state.now) / 86_400_000)) : undefined
  })
  const plus = createMemo(() => {
    const members = accounts().filter((account) => account.plan === "plus" && account.enabled && account.authenticated)
    return {
      total: members.length,
      ready: members.filter((account) => account.cooldownSeconds <= 0 && subscriptionCapacity(account, state.now) === "available").length,
    }
  })
  const ready = () => subscription()?.status === "ok"
  const refresh = () => {
    setState("now", Date.now())
    void actions.refetch()
  }
  createEffect(() => {
    source()
    setState("open", false)
    props.onOpenChange?.(false)
  })
  const timer = setInterval(() => {
    if (!document.hidden) refresh()
  }, 60_000)
  onCleanup(() => clearInterval(timer))
  const percent = (value: number) =>
    new Intl.NumberFormat(language.intl(), {
      style: "percent",
      maximumFractionDigits: 0,
    }).format(value / 100)
  const date = (value: number | string) =>
    new Intl.DateTimeFormat(language.intl(), {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(new Date(value))
  const updated = () => {
    const at = pool().observedAt
    if (at === null)
      return language.t("context.overview.measurements", { measured: pool().measured, total: pool().total })
    const minutes = Math.max(0, Math.floor((state.now - at) / 60_000))
    return language.t("context.overview.updated", {
      time: new Intl.RelativeTimeFormat(language.intl(), { numeric: "auto" }).format(
        minutes >= 60 ? -Math.floor(minutes / 60) : -minutes,
        minutes >= 60 ? "hour" : "minute",
      ),
    })
  }
  const status = () =>
    language.t(
      subscription()?.status === "unconfigured" ? "context.overview.unconfigured" : "context.overview.unavailable",
    )

  return (
    <div
      data-slot="sidebar-subscriptions"
      class="shrink-0 border-t border-border-weak-base pt-1.5 pb-1 [app-region:no-drag]"
    >
      <SubscriptionSurface
        mobile={props.mobile}
        open={state.open}
        onOpenChange={(open) => {
          setState("open", open)
          props.onOpenChange?.(open)
        }}
        title={language.t("sidebar.proxy.title")}
        label={language.t("sidebar.proxy.details")}
        trigger={
          <>
            <Show when={subscription()} fallback={<Spinner class="size-3 shrink-0" />}>
              <span
                class="size-1.5 shrink-0 rounded-full"
                classList={{
                  "bg-icon-success-base": ready() && pool().ready > 0,
                  "bg-icon-warning-base": !ready() || pool().ready === 0,
                }}
              />
            </Show>
            <span class="shrink-0 text-text-base">{language.t("sidebar.proxy.title")}</span>
            <span class="ms-auto min-w-0 truncate tabular-nums">
              {ready()
                ? language.t("sidebar.proxy.balance", {
                    percent: pool().availableRemaining !== null
                      ? percent(pool().availableRemaining!)
                      : pool().balance === "unavailable" ? percent(0) : "—",
                  })
                : language.t(subscription() ? "sidebar.proxy.unavailable" : "common.loading")}
            </span>
          <Show when={ready()}>
            <Show when={nextRenewal() !== undefined}>
              <span class="flex shrink-0 items-center gap-1 tabular-nums" title={language.t("sidebar.proxy.renewal")}>
                <Icon name="clock" size="small" />
                {language.plural("sidebar.proxy.renewalDays", nextRenewal() ?? 0)}
              </span>
            </Show>
              <span class="flex shrink-0 items-center gap-1 tabular-nums" title={language.t("context.overview.banked")}>
                <Icon name="refresh" size="small" />
                {pool().banked?.available ?? "—"}
              </span>
            </Show>
            <Icon name="chevron-down" size="small" class={state.open ? "shrink-0" : "shrink-0 rotate-180"} />
          </>
        }
      >
        <div class="flex min-w-0 flex-col gap-3 text-13-regular text-text-base">
          <div class="flex items-center justify-between gap-2">
            <span class="text-12-regular text-v2-text-text-muted">
              {ready() ? updated() : language.t("context.overview.subscriptions")}
            </span>
            <IconButton
              variant="ghost"
              size="small"
              disabled={resource.loading}
              aria-label={language.t("context.overview.refresh")}
              onClick={refresh}
              icon={resource.loading ? <Spinner class="size-3.5" /> : <Icon name="refresh" size="small" />}
            />
          </div>
          <Show when={subscription()} fallback={<p role="status">{language.t("common.loading")}</p>}>
            <Show when={ready()} fallback={<p role="status">{status()}</p>}>
              <Show when={accounts().length} fallback={<p>{language.t("context.overview.noSubscriptions")}</p>}>
                <div class="flex flex-col gap-2">
                  <span class="text-13-medium text-text-strong">{language.t("context.overview.availablePool")}</span>
                  <span>
                    {language.t("context.overview.availablePoolCapacity", { ready: pool().ready, total: pool().total })}
                  </span>
                  <span class="text-12-regular text-v2-text-text-muted">
                    {pool().total === 0
                      ? language.t("context.overview.noPool")
                      : pool().balance === "unknown"
                        ? language.t("context.overview.unknownWeekly")
                        : pool().balance === "unavailable"
                          ? language.t("context.overview.noAvailableBalance")
                          : language.t("context.overview.availablePoolRemaining", {
                              percent: percent(pool().availableRemaining ?? 0),
                            })}
                  </span>
                  <QuotaMeter value={pool().availableRemaining} label={language.t("context.overview.availablePool")} />
                  <Show when={pool().measured < pool().total && pool().observedAt !== null}>
                    <span class="text-12-regular text-v2-text-text-muted">
                      {language.t("context.overview.measurements", { measured: pool().measured, total: pool().total })}
                    </span>
                  </Show>
                </div>
                <div class="flex flex-col gap-1 border-t border-border-weak-base pt-3 text-12-regular text-v2-text-text-muted">
                  <div class="flex items-center justify-between gap-2">
                    <span>{language.t("context.overview.banked")}</span>
                    <span class="tabular-nums text-text-base">
                      {pool().banked?.available ?? language.t("context.overview.bankedUnknown")}
                    </span>
                  </div>
                  <Show when={(pool().banked?.available ?? 0) > 0}>
                    <span>
                      {language.t("context.overview.expiryMin", {
                        date:
                          pool().banked?.earliest == null
                            ? language.t("context.overview.noExpiry")
                            : date(pool().banked!.earliest!),
                      })}
                    </span>
                    <span>
                      {language.t("context.overview.expiryMax", {
                        date:
                          (pool().banked?.nonExpiring ?? 0) > 0
                            ? language.t("context.overview.noExpiry")
                            : date(pool().banked?.latest ?? 0),
                      })}
                    </span>
                  </Show>
                </div>
                <hr class="border-0 border-t border-border-weak-base" />
                <span class="text-12-regular text-v2-text-text-muted">
                  {language.t("sidebar.proxy.plusCapacity", { ready: plus().ready, total: plus().total })}
                </span>
                <details class="group border-t border-border-weak-base pt-2" data-slot="subscription-pool">
                  <summary class="flex h-8 cursor-pointer list-none items-center gap-2 rounded-sm text-13-medium text-text-strong focus-visible:outline-2 focus-visible:outline-border-active [&::-webkit-details-marker]:hidden">
                    <Icon name="chevron-down" size="small" class="-rotate-90 group-open:rotate-0" />
                    {language.t("sidebar.proxy.accounts")}
                    <span class="ms-auto tabular-nums text-v2-text-text-muted">{accounts().length}</span>
                  </summary>
                  <For each={accounts()}>
                    {(account) => {
                      const capacity = () => subscriptionCapacity(account, state.now)
                      return (
                        <div
                          role="group"
                          aria-label={account.name}
                          class="flex min-w-0 flex-col gap-2 border-t border-border-weak-base py-3"
                        >
                          <bdi class="break-all text-13-medium text-text-strong">{account.name}</bdi>
                          <span class="text-12-regular text-v2-text-text-muted">
                            {account.plan
                              ? language.t("context.overview.plan", {
                                  plan:
                                    account.plan === "pro"
                                      ? "Pro 20x"
                                      : account.plan === "prolite"
                                        ? "Pro 5x"
                                        : account.plan === "plus"
                                          ? "Plus"
                                          : account.plan,
                                })
                              : language.t("context.overview.planUnknown")}
                          </span>
                          <span>
                            {account.remaining === null
                              ? language.t("context.overview.unknownWeekly")
                              : language.t("context.overview.accountUsage", {
                                  remaining: percent(account.remaining),
                                  used: percent(100 - account.remaining),
                                })}
                          </span>
                          <QuotaMeter
                            value={account.remaining}
                            label={language.t("context.overview.weeklyAccount", { account: account.name })}
                          />
                          <Show when={account.resetAt}>
                            {(reset) => (
                              <span class="text-12-regular text-v2-text-text-muted">
                                {language.t("context.overview.weeklyReset", { time: date(reset()) })}
                              </span>
                            )}
                          </Show>
                          <Show when={account.fiveHourRemaining !== null || account.fiveHourResetAt !== null}>
                            <span class="text-12-regular text-v2-text-text-muted">
                              {account.fiveHourResetAt
                                ? language.t("context.overview.fiveHourReset", { time: date(account.fiveHourResetAt) })
                                : language.t("context.overview.fiveHour")}
                            </span>
                            <QuotaMeter
                              value={account.fiveHourRemaining}
                              label={language.t("context.overview.fiveHourAccount", { account: account.name })}
                            />
                          </Show>
                          <span class="text-12-regular text-v2-text-text-muted">
                            {account.bankedResets === null
                              ? language.t("context.overview.accountBankedUnknown")
                              : language.plural("context.overview.accountBanked", account.bankedResets.available)}
                          </span>
                          <Show when={account.plan === "plus" || account.plan === "prolite"}>
                            <span class="text-12-regular text-v2-text-text-muted">
                              {language.t("context.overview.resetProOnly")}
                            </span>
                          </Show>
                          <span class="text-12-regular text-v2-text-text-muted">
                            {language.t(
                              !account.enabled
                                ? "context.overview.disabled"
                                : !account.authenticated
                                  ? "context.overview.reauthenticate"
                                  : account.cooldownSeconds > 0
                                    ? "context.overview.cooldown"
                                    : account.stale || capacity() === "unconfirmed"
                                      ? "context.overview.capacityUnconfirmed"
                                      : capacity() === "outside"
                                        ? "context.overview.outsidePool"
                                        : account.hasCapacity === false
                                          ? "context.overview.noCapacity"
                                          : "context.overview.available",
                            )}
                          </span>
                        </div>
                      )
                    }}
                  </For>
                </details>
              </Show>
            </Show>
          </Show>
        </div>
      </SubscriptionSurface>
    </div>
  )
}

function SubscriptionSurface(props: {
  mobile?: boolean
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  label: string
  trigger: JSX.Element
  children: JSX.Element
}) {
  const language = useLanguage()
  const triggerClass = "flex w-full min-w-0 items-center gap-2 rounded-md px-2 text-12-regular text-v2-text-text-muted hover:bg-v2-background-bg-layer-02 focus-visible:outline-2 focus-visible:outline-border-active"
  return <Show when={props.mobile} fallback={
    <Popover open={props.open} onOpenChange={props.onOpenChange} placement="top-start" gutter={8}
      title={props.title}
      class="w-[360px] max-w-[calc(100vw-24px)] [&_[data-slot=popover-body]]:max-h-[65vh] [&_[data-slot=popover-body]]:overflow-y-auto"
      triggerAs="button" triggerProps={{ type: "button", "aria-label": props.label, class: `${triggerClass} h-8` }}
      trigger={props.trigger}>{props.children}</Popover>
  }>
    <Show when={props.open} fallback={
      <button type="button" aria-label={props.label} class={`${triggerClass} h-11`} onClick={() => props.onOpenChange(true)}>{props.trigger}</button>
    }>
      <div class="flex min-h-0 flex-col" data-slot="mobile-proxy-details">
        <button type="button" class="flex h-11 shrink-0 items-center gap-2 px-2 text-13-medium text-text-strong focus-visible:outline-2 focus-visible:outline-border-active" onClick={() => props.onOpenChange(false)}>
          <Icon name="chevron-left" size="small" />
          {language.t("sidebar.proxy.back")}
        </button>
        <div class="max-h-[65dvh] overflow-y-auto overscroll-contain px-2 pb-3">
          <h2 class="mb-3 text-14-medium text-text-strong">{props.title}</h2>
          {props.children}
        </div>
      </div>
    </Show>
  </Show>
}

function QuotaMeter(props: { value: number | null; label: string }) {
  return (
    <div
      role="meter"
      aria-label={props.label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={props.value ?? undefined}
      class="h-1 w-full overflow-hidden rounded-full bg-surface-raised-base"
    >
      <div
        class="h-full rounded-full"
        classList={{
          "bg-icon-critical-base": props.value !== null && props.value < 10,
          "bg-icon-warning-base": props.value !== null && props.value >= 10 && props.value < 30,
          "bg-icon-success-base": props.value !== null && props.value >= 30,
        }}
        style={{ width: `${Math.max(0, Math.min(100, props.value ?? 0))}%` }}
      />
    </div>
  )
}
