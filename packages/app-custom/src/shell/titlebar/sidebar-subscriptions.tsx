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
import {
  subscriptionAccounts,
  subscriptionCapacity,
  subscriptionPace,
  subscriptionPool,
} from "@/session/files/subscription-pool"
import { formatSubscriptionDate } from "./subscription-date"

export function SidebarSubscriptions(props: {
  currentTab?: Tab
  mobile?: boolean
  onOpenChange?: (open: boolean) => void
}) {
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
  const groups = createMemo(() =>
    [...new Set(accounts().map((account) => account.plan))].map((plan) => ({
      plan,
      accounts: accounts().filter((account) => account.plan === plan),
    })),
  )
  const renewals = createMemo(() => {
    const resets = accounts().flatMap((account) =>
      account.plan === "pro" && account.enabled && account.authenticated && account.resetAt
        ? [Date.parse(account.resetAt)]
        : [],
    )
    return resets.length ? { min: Math.min(...resets), max: Math.max(...resets) } : undefined
  })
  const nextRenewal = createMemo(() => {
    const first = renewals()?.min
    return first === undefined ? undefined : Math.max(0, Math.ceil((first - state.now) / 86_400_000))
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
  const date = (value: number | string, weekdayFirst = false) =>
    formatSubscriptionDate(value, language.intl(), weekdayFirst)
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
                ? language.t("sidebar.proxy.quota", {
                    percent: pool().availableRemaining !== null ? percent(pool().availableRemaining!) : "—",
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
                <For each={groups()}>
                  {(group) => {
                    const summary = createMemo(() => subscriptionPool(group.accounts, state.now, group.plan ?? ""))
                    const title = () =>
                      group.plan === "pro" || group.plan === "prolite" || group.plan === "plus"
                        ? language.t(`sidebar.proxy.${group.plan}`)
                        : (group.plan ?? language.t("context.overview.planUnknown"))
                    return (
                      <section
                        aria-label={title()}
                        class="flex min-w-0 flex-col gap-3 border-b border-border-weak-base pb-3 last:border-0"
                        data-slot="subscription-plan"
                      >
                        <div class="flex flex-wrap items-baseline justify-between gap-2">
                          <h3 class="text-13-medium text-text-strong">{title()}</h3>
                          <span class="text-12-regular text-v2-text-text-muted tabular-nums">
                            {language.t("sidebar.proxy.groupCapacity", {
                              ready: summary().ready,
                              total: group.accounts.length,
                            })}
                          </span>
                        </div>
                        <Show when={group.plan !== "plus"}>
                          <span class="text-12-regular text-v2-text-text-muted">
                            {language.t("context.overview.weekly")}
                          </span>
                        </Show>
                        <For each={group.accounts}>
                          {(account) => <SubscriptionAccount account={account} now={state.now} />}
                        </For>
                        <div class="flex flex-col gap-1 text-12-regular text-v2-text-text-muted">
                          <span>
                            {language.t(
                              group.plan === "plus"
                                ? "sidebar.proxy.combinedWeekly"
                                : "context.overview.totalQuotaRemaining",
                              {
                                percent:
                                  summary().availableRemaining === null ? "—" : percent(summary().availableRemaining!),
                              },
                            )}
                          </span>
                          <Show when={group.plan === "plus"}>
                            <span>
                              {language.t("sidebar.proxy.combinedFiveHour", {
                                percent:
                                  summary().fiveHourRemaining === null ? "—" : percent(summary().fiveHourRemaining!),
                              })}
                            </span>
                          </Show>
                          <Show when={group.plan === "pro"}>
                            <span>
                              {summary().banked === null
                                ? language.t("context.overview.accountBankedUnknown")
                                : language.plural("context.overview.accountBanked", summary().banked!.available)}
                            </span>
                            <Show when={(summary().banked?.available ?? 0) > 0}>
                              <span>
                                {language.t("context.overview.expiryMin", {
                                  date:
                                    summary().banked?.earliest == null
                                      ? language.t("context.overview.noExpiry")
                                      : date(summary().banked!.earliest!),
                                })}
                              </span>
                            </Show>
                          </Show>
                        </div>
                      </section>
                    )
                  }}
                </For>
              </Show>
            </Show>
          </Show>
        </div>
      </SubscriptionSurface>
    </div>
  )
}

function SubscriptionAccount(props: { account: Subscriptions.Account; now: number }) {
  const language = useLanguage()
  const account = () => props.account
  const capacity = () => subscriptionCapacity(account(), props.now)
  const percent = (value: number | null) =>
    value === null
      ? "—"
      : new Intl.NumberFormat(language.intl(), { style: "percent", maximumFractionDigits: 0 }).format(value / 100)
  const remaining = (value: number | null) => (account().stale || capacity() === "unconfirmed" ? null : value)
  const date = (value: string) => formatSubscriptionDate(value, language.intl(), true)
  const pace = () => subscriptionPace(account(), props.now)
  const status = () => {
    if (!account().enabled) return "context.overview.disabled"
    if (!account().authenticated) return "context.overview.reauthenticate"
    if (account().cooldownSeconds > 0) return "context.overview.cooldown"
    if (capacity() === "unconfirmed") return "context.overview.capacityUnconfirmed"
    if (capacity() === "outside") return "context.overview.outsidePool"
    if (capacity() === "unavailable" && account().remaining === 0) return "sidebar.proxy.weeklyExhausted"
    if (capacity() === "unavailable" && account().fiveHourRemaining === 0) return "sidebar.proxy.fiveHourExhausted"
    if (capacity() === "unavailable") return "context.overview.noCapacity"
  }
  return (
    <div role="group" aria-label={account().name} class="flex min-w-0 flex-col gap-2 py-1">
      <div class="flex min-w-0 items-center justify-between gap-2 text-12-regular">
        <bdi class="min-w-0 truncate" title={account().name}>
          {account().name}
        </bdi>
        <Show when={account().plan !== "plus"}>
          <span class="shrink-0 tabular-nums">{percent(remaining(account().remaining))}</span>
        </Show>
      </div>
      <Show when={account().plan === "plus"}>
        <div class="flex justify-between gap-2 text-12-regular text-v2-text-text-muted">
          <span>{language.t("context.overview.weekly")}</span>
          <span class="tabular-nums">{percent(remaining(account().remaining))}</span>
        </div>
      </Show>
      <QuotaMeter
        value={remaining(account().remaining)}
        label={language.t("context.overview.weeklyAccount", { account: account().name })}
        pace={pace()}
        paceLabel={
          pace() === null ? undefined : language.t("context.overview.balancePace", { percent: percent(pace()) })
        }
      />
      <span class="text-12-regular text-v2-text-text-muted">
        {language.t("sidebar.proxy.renews", { date: account().resetAt ? date(account().resetAt!) : "—" })}
      </span>
      <Show
        when={account().plan === "plus" || account().fiveHourRemaining !== null || account().fiveHourResetAt !== null}
      >
        <div class="flex justify-between gap-2 text-12-regular text-v2-text-text-muted">
          <span>{language.t("context.overview.fiveHour")}</span>
          <span class="tabular-nums">{percent(remaining(account().fiveHourRemaining))}</span>
        </div>
        <QuotaMeter
          value={remaining(account().fiveHourRemaining)}
          label={language.t("context.overview.fiveHourAccount", { account: account().name })}
        />
        <span class="text-12-regular text-v2-text-text-muted">
          {language.t("sidebar.proxy.renews", {
            date: account().fiveHourResetAt ? date(account().fiveHourResetAt!) : "—",
          })}
        </span>
      </Show>
      <Show when={account().plan === "pro"}>
        <div class="flex flex-col gap-1 text-12-regular text-v2-text-text-muted">
          <span>
            {account().bankedResets === null
              ? language.t("context.overview.accountBankedUnknown")
              : language.plural("context.overview.accountBanked", account().bankedResets!.available)}
          </span>
          <Show when={(account().bankedResets?.available ?? 0) > 0}>
            <span>
              {language.t("context.overview.expiryMin", {
                date: account().bankedResets?.earliestExpiresAt
                  ? date(account().bankedResets!.earliestExpiresAt!)
                  : language.t("context.overview.noExpiry"),
              })}
            </span>
          </Show>
        </div>
      </Show>
      <Show when={status()}>
        {(key) => <span class="text-12-regular text-v2-text-text-muted">{language.t(key())}</span>}
      </Show>
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
  const triggerClass =
    "flex w-full min-w-0 items-center gap-2 rounded-md px-2 text-12-regular text-v2-text-text-muted hover:bg-v2-background-bg-layer-02 focus-visible:outline-2 focus-visible:outline-border-active"
  return (
    <Show
      when={props.mobile}
      fallback={
        <Popover
          open={props.open}
          onOpenChange={props.onOpenChange}
          placement="top-start"
          gutter={8}
          title={props.title}
          class="w-[360px] max-w-[calc(100vw-24px)] [&_[data-slot=popover-body]]:max-h-[65vh] [&_[data-slot=popover-body]]:overflow-y-auto"
          triggerAs="button"
          triggerProps={{ type: "button", "aria-label": props.label, class: `${triggerClass} h-8` }}
          trigger={props.trigger}
        >
          {props.children}
        </Popover>
      }
    >
      <Show
        when={props.open}
        fallback={
          <button
            type="button"
            aria-label={props.label}
            class={`${triggerClass} h-11`}
            onClick={() => props.onOpenChange(true)}
          >
            {props.trigger}
          </button>
        }
      >
        <div class="flex min-h-0 flex-col" data-slot="mobile-proxy-details">
          <button
            type="button"
            class="flex h-11 shrink-0 items-center gap-2 px-2 text-13-medium text-text-strong focus-visible:outline-2 focus-visible:outline-border-active"
            onClick={() => props.onOpenChange(false)}
          >
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
  )
}

function QuotaMeter(props: { value: number | null; label: string; pace?: number | null; paceLabel?: string }) {
  return (
    <div
      role="meter"
      aria-label={props.label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={props.value ?? undefined}
      aria-description={props.paceLabel}
      title={props.paceLabel}
      class="relative h-1 w-full rounded-full bg-surface-raised-base"
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
      <Show when={props.value !== null && props.pace != null}>
        <span
          data-slot="quota-pace"
          aria-hidden="true"
          class="pointer-events-none absolute -top-1 h-3 w-0.5 rounded-full bg-icon-critical-base"
          style={{ "inset-inline-start": `clamp(0px, calc(${props.pace}% - 1px), calc(100% - 2px))` }}
        />
      </Show>
    </div>
  )
}
