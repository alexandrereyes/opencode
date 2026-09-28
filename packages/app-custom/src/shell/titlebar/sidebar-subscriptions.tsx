import { createEffect, createMemo, createResource, For, onCleanup, Show, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { Popover } from "@opencode/ui-custom/popover"
import { ProviderIcon } from "@opencode/ui-custom/provider-icon"
import { SegmentedControl, SegmentedControlItem } from "@opencode/ui-custom/segmented-control"
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
import {
  formatSubscriptionCountdown,
  formatSubscriptionDate,
  formatSubscriptionExpiry,
  formatSubscriptionShortDate,
} from "./subscription-date"

export function SidebarSubscriptions(props: {
  currentTab?: Tab
  mobile?: boolean
  onOpenChange?: (open: boolean) => void
}) {
  const global = useGlobal()
  const language = useLanguage()
  const [state, setState] = createStore({ open: false, now: Date.now(), provider: "codex" as Provider })
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
      // Quota status is process-global; the request uses the server default Location.
      return { ctx, directory: directory ?? "" }
    },
    undefined,
    { equals: (a, b) => a?.ctx === b?.ctx && a?.directory === b?.directory },
  )
  const [resource, actions] = createResource(source, async (source) => ({
    source,
    data: await source.ctx.sdk.api
      .rpc(Subscriptions.Definition)
      .list({})
      .catch(() => ({
        status: "unavailable" as const,
        accounts: [],
        anthropic: { status: "unavailable" as const, accounts: [] },
      })),
  }))
  // An optional status must not suspend the shell while its first request is pending.
  const subscription = () => {
    const result = resource.state === "ready" || resource.state === "refreshing" ? resource.latest : undefined
    return result && result.source === source() ? result.data : undefined
  }
  const view = (provider: Provider) => {
    const data = createMemo(() => {
      const info = subscription()
      if (!info) return
      return provider === "codex" ? { status: info.status, accounts: info.accounts } : info.anthropic
    })
    const unit = PROVIDERS[provider].unit
    const accounts = createMemo(() => subscriptionAccounts(data()?.accounts ?? [], state.now))
    const renewals = createMemo(() => {
      const resets = accounts().flatMap((account) =>
        account.plan === unit && account.enabled && account.authenticated && account.resetAt
          ? [Date.parse(account.resetAt)]
          : [],
      )
      return resets.length ? { min: Math.min(...resets), max: Math.max(...resets) } : undefined
    })
    return {
      provider,
      data,
      accounts,
      renewals,
      pool: createMemo(() => subscriptionPool(data()?.accounts ?? [], state.now, unit)),
      groups: createMemo(() =>
        [...new Set(accounts().map((account) => account.plan))].map((plan) => ({
          plan,
          accounts: accounts().filter((account) => account.plan === plan),
        })),
      ),
      nextRenewal: createMemo(() => {
        const first = renewals()?.min
        return first === undefined ? undefined : Math.max(0, Math.ceil((first - state.now) / 86_400_000))
      }),
      ready: () => data()?.status === "ok",
    }
  }
  const codex = view("codex")
  const anthropic = view("anthropic")
  const providers = createMemo(() => {
    const status = subscription()?.anthropic.status
    return status === undefined || status === "disabled" ? [codex] : [codex, anthropic]
  })
  const selected = () => (state.provider === "anthropic" && providers().includes(anthropic) ? anthropic : codex)
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
  const equivalents = (item: typeof codex) =>
    item.pool().equivalents === null
      ? "—"
      : new Intl.NumberFormat(language.intl(), {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        }).format(item.pool().equivalents!)
  const date = (value: number | string, weekdayFirst = false) =>
    formatSubscriptionDate(value, language.intl(), weekdayFirst)
  const shortDate = (value: number) => formatSubscriptionShortDate(value, language.intl())
  const planLabel = (plan: string | null) =>
    plan === "pro" || plan === "prolite" || plan === "plus" || plan === "max20x" || plan === "max5x"
      ? language.t(`sidebar.proxy.${plan}`)
      : (plan ?? language.t("context.overview.planUnknown"))
  const updated = () => {
    const pool = selected().pool()
    const at = pool.observedAt
    if (at === null) return language.t("context.overview.measurements", { measured: pool.measured, total: pool.total })
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
      selected().data()?.status === "unconfigured" ? "context.overview.unconfigured" : "context.overview.unavailable",
    )

  return (
    <div
      data-slot="sidebar-subscriptions"
      class="shrink-0 border-t border-border-weak-base pt-1 pb-1 [app-region:no-drag]"
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
          <div class="flex w-full min-w-0 flex-col gap-0.5 leading-text-compact">
            <div class="flex items-center justify-between gap-2 px-1.5 pt-1 text-[length:var(--font-size-x-small)] font-medium uppercase leading-[var(--line-height-tight)] tracking-[0.06em] text-v2-text-text-faint">
              <span>{language.t("sidebar.proxy.title")}</span>
              <Icon name="chevron-down" size="small" class={state.open ? "shrink-0" : "shrink-0 rotate-180"} />
            </div>
            <div class="grid grid-cols-[auto_minmax(0,1fr)_auto_auto] gap-x-2 whitespace-nowrap">
              <For each={providers()}>
                {(item) => (
                  <div
                    class="col-span-full grid grid-cols-subgrid grid-rows-[repeat(2,var(--line-height-compact))] items-center gap-y-1 rounded-md px-1.5 py-1.5 hover:bg-v2-background-bg-layer-02 data-[selected]:bg-v2-background-bg-layer-02"
                    data-slot="subscription-provider"
                    data-provider={item.provider}
                    data-selected={state.open && selected() === item ? "" : undefined}
                    onClick={() => setState("provider", item.provider)}
                  >
                    <span class="col-start-1 row-span-2 row-start-1 flex size-7 items-center justify-center rounded-md border border-border-weak-base bg-v2-background-bg-base text-v2-icon-icon-base">
                      <ProviderIcon id={PROVIDERS[item.provider].icon} width={14} height={14} />
                    </span>
                    <span class="col-start-2 row-start-1 flex min-w-0 items-center gap-1.5">
                      <Show when={subscription()} fallback={<Spinner class="size-3 shrink-0" />}>
                        <span
                          class="size-1.5 shrink-0 rounded-full"
                          classList={{
                            "bg-icon-success-base": item.ready() && item.pool().ready > 0,
                            "bg-icon-warning-base": !item.ready() || item.pool().ready === 0,
                          }}
                        />
                      </Show>
                      <span class="truncate text-text-base">{language.t(PROVIDERS[item.provider].keys.label)}</span>
                    </span>
                    <span class="col-start-2 row-start-2 flex items-center">
                      <QuotaMeter
                        value={item.ready() ? item.pool().availableRemaining : null}
                        label={language.t("context.overview.weeklyAccount", {
                          account: language.t(PROVIDERS[item.provider].keys.label),
                        })}
                      />
                    </span>
                    <span
                      class="col-start-3 row-start-1 tabular-nums"
                      title={
                        item.pool().equivalents === null ? language.t(PROVIDERS[item.provider].keys.unknown) : undefined
                      }
                    >
                      <Show
                        when={item.ready()}
                        fallback={language.t(subscription() ? "sidebar.proxy.unavailable" : "common.loading")}
                      >
                        <span class="font-semibold text-text-strong">{equivalents(item)}</span>
                        <span class="ms-1">{language.t(PROVIDERS[item.provider].keys.plan)}</span>
                      </Show>
                    </span>
                    <span class="col-start-3 row-start-2 flex items-center">
                      <Show
                        when={item.provider === "anthropic" && item.ready() && item.pool().fiveHourRemaining !== null}
                      >
                        <span
                          class={`${BADGE} ${TONE[quotaTone(item.pool().fiveHourRemaining!)]} tabular-nums`}
                          title={language.t("sidebar.proxy.fiveHourAverage")}
                        >
                          {language.t("sidebar.proxy.fiveHourShort", {
                            percent: percent(item.pool().fiveHourRemaining!),
                          })}
                        </span>
                      </Show>
                    </span>
                    <span
                      class="col-start-4 row-start-1 flex items-center gap-1 justify-self-end tabular-nums"
                      title={language.t(PROVIDERS[item.provider].keys.renewal)}
                    >
                      <Show when={item.ready() && item.nextRenewal() !== undefined}>
                        <Icon name="clock" size="small" />
                        {language.plural("sidebar.proxy.renewalDays", item.nextRenewal() ?? 0)}
                      </Show>
                    </span>
                    <span
                      class="col-start-4 row-start-2 flex items-center gap-1 justify-self-end tabular-nums"
                      title={language.t(PROVIDERS[item.provider].keys.banked)}
                    >
                      <Show when={item.ready()}>
                        <Icon name="refresh" size="small" />
                        {item.pool().banked?.available ?? "—"}
                      </Show>
                    </span>
                  </div>
                )}
              </For>
            </div>
          </div>
        }
      >
        <div class="flex min-w-0 flex-col gap-3 text-13-regular text-text-base">
          <Show when={providers().length > 1}>
            <SegmentedControl
              class="segmented-control-v2--full-width"
              aria-label={language.t("sidebar.proxy.providers")}
              value={selected().provider}
              onChange={(value) => {
                if (value) setState("provider", value === "anthropic" ? "anthropic" : "codex")
              }}
            >
              <For each={providers()}>
                {(item) => (
                  <SegmentedControlItem value={item.provider}>
                    <span class="flex items-center gap-1.5">
                      <ProviderIcon id={PROVIDERS[item.provider].icon} width={14} height={14} class="shrink-0" />
                      {language.t(PROVIDERS[item.provider].keys.label)}
                    </span>
                  </SegmentedControlItem>
                )}
              </For>
            </SegmentedControl>
          </Show>
          <Show
            when={subscription()}
            fallback={
              <p role="status" class="text-12-regular text-v2-text-text-muted">
                {language.t("common.loading")}
              </p>
            }
          >
            <Show when={selected()} keyed>
              {(item) => (
                <Show
                  when={item.ready()}
                  fallback={
                    <p role="status" class="text-12-regular text-v2-text-text-muted">
                      {status()}
                    </p>
                  }
                >
                  <Show
                    when={item.accounts().length}
                    fallback={
                      <p class="text-12-regular text-v2-text-text-muted">
                        {language.t("context.overview.noSubscriptions")}
                      </p>
                    }
                  >
                    <section
                      aria-label={language.t(PROVIDERS[item.provider].keys.label)}
                      class="flex min-w-0 flex-col overflow-hidden rounded-lg border border-border-weak-base bg-v2-background-bg-layer-01"
                      data-slot="subscription-card"
                    >
                      <header class="flex min-w-0 flex-col gap-2.5 p-3">
                        <div class="flex min-w-0 items-center gap-3">
                          <span class="flex size-9 shrink-0 items-center justify-center rounded-lg border border-border-weak-base bg-v2-background-bg-base text-v2-icon-icon-base">
                            <ProviderIcon id={PROVIDERS[item.provider].icon} width={18} height={18} />
                          </span>
                          <div class="flex min-w-0 flex-1 flex-col">
                            <h3 class="truncate text-14-medium text-text-strong">
                              {language.t(PROVIDERS[item.provider].keys.label)}
                            </h3>
                            <span class="truncate text-12-regular leading-text-compact text-v2-text-text-muted">
                              {language.t("sidebar.proxy.poolSummary", {
                                plans: new Intl.ListFormat(language.intl(), { type: "unit" }).format(
                                  item.groups().map((group) => planLabel(group.plan)),
                                ),
                                accounts: language.plural("sidebar.proxy.accountCount", item.accounts().length),
                              })}
                            </span>
                          </div>
                          <div
                            class="flex shrink-0 flex-col items-end"
                            title={
                              item.pool().equivalents === null
                                ? language.t(PROVIDERS[item.provider].keys.unknown)
                                : undefined
                            }
                          >
                            <span class="text-20-medium leading-6 text-text-strong tabular-nums">
                              {equivalents(item)}
                            </span>
                            <span class="text-12-regular leading-text-compact text-v2-text-text-muted">
                              {language.t(PROVIDERS[item.provider].keys.plan)}
                            </span>
                          </div>
                        </div>
                        <QuotaMeter
                          class="h-1.5"
                          value={item.pool().availableRemaining}
                          label={language.t("context.overview.weeklyAccount", {
                            account: language.t("sidebar.proxy.totalQuotaRemaining"),
                          })}
                          pace={item.pool().expectedRemaining}
                          paceLabel={
                            item.pool().expectedRemaining === null
                              ? undefined
                              : language.t("context.overview.balancePace", {
                                  percent: percent(item.pool().expectedRemaining!),
                                })
                          }
                        />
                        <div class="flex items-center justify-between gap-2 text-12-regular leading-text-compact text-v2-text-text-muted">
                          <span class="min-w-0 truncate">
                            {language.t("sidebar.proxy.totalQuotaRemaining")}{" "}
                            <span class="text-text-strong tabular-nums">
                              {item.pool().availableRemaining === null ? "—" : percent(item.pool().availableRemaining!)}
                            </span>
                          </span>
                          <Show when={item.groups().length === 1}>
                            <span class="shrink-0 tabular-nums">
                              {language.t("sidebar.proxy.groupCapacity", {
                                ready: item.pool().ready,
                                total: item.pool().total,
                              })}
                            </span>
                          </Show>
                        </div>
                      </header>
                      <div class="flex min-w-0 flex-col gap-4 border-t border-border-weak-base p-3">
                        <For each={item.groups()}>
                          {(group) => (
                            <div role="group" aria-label={planLabel(group.plan)} class="flex min-w-0 flex-col gap-3">
                              <Show when={item.groups().length > 1}>
                                <div class="flex items-center justify-between gap-2 text-[length:var(--font-size-x-small)] font-medium uppercase leading-[var(--line-height-tight)] tracking-[0.06em] text-v2-text-text-faint">
                                  <span>{planLabel(group.plan)}</span>
                                  <span class="tabular-nums">
                                    {language.t("sidebar.proxy.groupCapacity", {
                                      ready: subscriptionPool(group.accounts, state.now, group.plan ?? "").ready,
                                      total: group.accounts.length,
                                    })}
                                  </span>
                                </div>
                              </Show>
                              <div class="flex min-w-0 flex-col gap-3">
                                <For each={group.accounts}>
                                  {(account, index) => (
                                    <>
                                      <Show when={index() > 0}>
                                        <hr class="m-0 w-full scale-y-50 border-0 border-t border-border-base" />
                                      </Show>
                                      <SubscriptionAccount account={account} now={state.now} />
                                    </>
                                  )}
                                </For>
                              </div>
                            </div>
                          )}
                        </For>
                      </div>
                      <footer class="flex flex-wrap border-t border-border-weak-base text-12-regular leading-text-compact text-v2-text-text-muted tabular-nums">
                        <span
                          class="flex min-w-0 flex-1 items-center gap-1.5 whitespace-nowrap px-3 py-2.5"
                          title={language.t("context.overview.renewalMin", {
                            date: item.renewals() ? date(item.renewals()!.min, true) : "—",
                          })}
                        >
                          <Icon name="clock" size="small" class="shrink-0" />
                          <span class="shrink-0 text-text-strong">
                            {item.nextRenewal() === undefined
                              ? "—"
                              : language.plural("sidebar.proxy.renewalDays", item.nextRenewal()!)}
                          </span>
                          <Show when={item.renewals()}>{(renewals) => <span>{shortDate(renewals().min)}</span>}</Show>
                        </span>
                        <span
                          class="flex min-w-0 items-center gap-1.5 border-s border-border-weak-base px-3 py-2.5"
                          title={
                            (item.pool().banked?.available ?? 0) > 0
                              ? language.t("context.overview.expiryMin", {
                                  date:
                                    item.pool().banked?.earliest == null
                                      ? language.t("context.overview.noExpiry")
                                      : date(item.pool().banked!.earliest!),
                                })
                              : undefined
                          }
                        >
                          <Icon name="refresh" size="small" class="shrink-0" />
                          <span class="truncate text-text-strong">
                            {item.pool().banked === null
                              ? language.t("context.overview.accountBankedUnknown")
                              : language.plural("sidebar.proxy.bankedCount", item.pool().banked!.available)}
                          </span>
                        </span>
                      </footer>
                    </section>
                  </Show>
                </Show>
              )}
            </Show>
          </Show>
          <div class="flex items-center justify-between gap-2 text-12-regular leading-text-compact text-v2-text-text-faint">
            <span>{selected().ready() ? updated() : language.t("context.overview.subscriptions")}</span>
            <IconButton
              variant="ghost"
              size="small"
              disabled={resource.loading}
              aria-label={language.t("context.overview.refresh")}
              onClick={refresh}
              icon={resource.loading ? <Spinner class="size-3.5" /> : <Icon name="refresh" size="small" />}
            />
          </div>
        </div>
      </SubscriptionSurface>
    </div>
  )
}

type Provider = "codex" | "anthropic"

const PROVIDERS = {
  codex: {
    unit: "pro",
    icon: "openai",
    keys: {
      label: "sidebar.proxy.codex",
      plan: "sidebar.proxy.pro",
      unknown: "sidebar.proxy.equivalentUnknown",
      renewal: "sidebar.proxy.renewal",
      banked: "context.overview.banked",
    },
  },
  anthropic: {
    unit: "max20x",
    icon: "anthropic",
    keys: {
      label: "sidebar.proxy.claude",
      plan: "sidebar.proxy.max20x",
      unknown: "sidebar.proxy.anthropicEquivalentUnknown",
      renewal: "sidebar.proxy.anthropicRenewal",
      banked: "sidebar.proxy.anthropicBanked",
    },
  },
} as const

function SubscriptionAccount(props: { account: Subscriptions.Account; now: number }) {
  const language = useLanguage()
  const account = () => props.account
  const capacity = () => subscriptionCapacity(account(), props.now)
  const percent = (value: number | null) =>
    value === null
      ? "—"
      : new Intl.NumberFormat(language.intl(), { style: "percent", maximumFractionDigits: 0 }).format(value / 100)
  const remaining = (value: number | null) => (account().stale || capacity() === "unconfirmed" ? null : value)
  const weeklyExhausted = () => remaining(account().remaining) === 0
  const renews = (value: string | null) =>
    language.t("sidebar.proxy.renews", { date: value ? formatSubscriptionDate(value, language.intl(), true) : "—" })
  const pace = () => (weeklyExhausted() ? null : subscriptionPace(account(), props.now))
  const status = () => {
    if (!account().enabled) return ACCOUNT_STATUS.disabled
    if (!account().authenticated) return ACCOUNT_STATUS.reauthenticate
    if (account().cooldownSeconds > 0) return ACCOUNT_STATUS.cooldown
    if (capacity() === "unconfirmed") return ACCOUNT_STATUS.unconfirmed
    if (capacity() === "outside") return ACCOUNT_STATUS.outside
    if (weeklyExhausted()) return ACCOUNT_STATUS.weeklyExhausted
    if (capacity() === "unavailable" && account().fiveHourRemaining === 0) return ACCOUNT_STATUS.fiveHourExhausted
    if (capacity() === "unavailable") return ACCOUNT_STATUS.noCapacity
    return ACCOUNT_STATUS.available
  }
  const windows = () => [
    ...(!weeklyExhausted() && (account().fiveHourRemaining !== null || account().fiveHourResetAt !== null)
      ? [
          {
            label: language.t("sidebar.proxy.windowFiveHour"),
            value: remaining(account().fiveHourRemaining),
            countdown: account().fiveHourResetAt
              ? formatSubscriptionExpiry(account().fiveHourResetAt!, props.now)
              : null,
            title: renews(account().fiveHourResetAt),
            meter: language.t("context.overview.fiveHourAccount", { account: account().name }),
            pace: null,
          },
        ]
      : []),
    {
      label: formatSubscriptionCountdown(account().resetAt, props.now),
      value: remaining(account().remaining),
      countdown: null,
      title: renews(account().resetAt),
      meter: language.t("context.overview.weeklyAccount", { account: account().name }),
      pace: pace(),
    },
  ]
  const value = (window: ReturnType<typeof windows>[number]) => (
    <span class="shrink-0 text-v2-text-text-muted">
      {window.label}{" "}
      <span
        class="tabular-nums"
        classList={{
          "text-v2-text-text-faint": window.value === null,
          "text-text-strong": window.value !== null && quotaTone(window.value) === "neutral",
          "text-v2-state-fg-warning": window.value !== null && quotaTone(window.value) === "warning",
          "text-v2-state-fg-danger": window.value !== null && quotaTone(window.value) === "danger",
        }}
      >
        {percent(window.value)}
      </span>
      <Show when={window.countdown}>{(countdown) => <span class="tabular-nums"> ({countdown()})</span>}</Show>
    </span>
  )
  const meter = (window: ReturnType<typeof windows>[number]) => (
    <QuotaMeter
      value={window.value}
      label={window.meter}
      pace={window.pace}
      paceLabel={
        window.pace === null ? undefined : language.t("context.overview.balancePace", { percent: percent(window.pace) })
      }
    />
  )
  return (
    <div role="group" aria-label={account().name} class="flex min-w-0 flex-col gap-2">
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1.5 text-12-regular leading-text-compact">
        <span class="flex w-full min-w-0 items-center justify-between gap-2 text-text-base">
          <bdi class="min-w-0 truncate font-[700]" title={account().name}>
            {account().name}
          </bdi>
          <span class="flex shrink-0 items-center gap-1 text-v2-text-text-muted tabular-nums">
            <Show when={account().bankedResets} fallback="—">
              {(banked) => language.plural("sidebar.proxy.accountResets", banked().available)}
            </Show>
            <Show when={(account().bankedResets?.available ?? 0) > 0 && account().bankedResets?.earliestExpiresAt}>
              {(expiry) => (
                <span
                  class="shrink-0 text-v2-text-text-muted tabular-nums"
                  title={language.t("context.overview.expiryMin", {
                    date: formatSubscriptionDate(expiry(), language.intl()),
                  })}
                >
                  ({formatSubscriptionExpiry(expiry(), props.now)})
                </span>
              )}
            </Show>
          </span>
        </span>
        <Show when={status()}>
          {(item) => (
            <span class={`${BADGE} ${TONE[item().tone]}`} title={language.t(item().title)}>
              {language.t(item().label)}
            </span>
          )}
        </Show>
        <Show when={windows().length === 1}>
          <span class="ms-auto" title={windows()[0].title}>
            {value(windows()[0])}
          </span>
        </Show>
      </div>
      <Show when={!weeklyExhausted()}>
        <Show when={windows().length > 1} fallback={<div title={windows()[0].title}>{meter(windows()[0])}</div>}>
          <div class="grid grid-cols-2 gap-4">
            <For each={windows()}>
              {(window) => (
                <div class="flex min-w-0 flex-col gap-1.5" title={window.title}>
                  <div class="flex text-12-regular leading-text-compact">{value(window)}</div>
                  {meter(window)}
                </div>
              )}
            </For>
          </div>
        </Show>
      </Show>
    </div>
  )
}

const BADGE =
  "inline-flex h-4 shrink-0 items-center rounded-[4px] border-[0.5px] px-1 text-[length:var(--font-size-x-small)] font-medium leading-[var(--line-height-tight)] whitespace-nowrap"

const TONE = {
  success: "border-v2-state-border-success bg-v2-state-bg-success text-v2-state-fg-success",
  neutral: "border-v2-border-border-base bg-v2-background-bg-layer-02 text-v2-text-text-muted",
  warning: "border-v2-state-border-warning bg-v2-state-bg-warning text-v2-state-fg-warning",
  danger: "border-v2-state-border-danger bg-v2-state-bg-danger text-v2-state-fg-danger",
} as const

const ACCOUNT_STATUS = {
  available: { label: "sidebar.proxy.badge.available", title: "sidebar.proxy.badge.available", tone: "success" },
  disabled: { label: "sidebar.proxy.badge.disabled", title: "context.overview.disabled", tone: "neutral" },
  reauthenticate: {
    label: "sidebar.proxy.badge.reauthenticate",
    title: "context.overview.reauthenticate",
    tone: "danger",
  },
  cooldown: { label: "sidebar.proxy.badge.cooldown", title: "context.overview.cooldown", tone: "warning" },
  unconfirmed: {
    label: "sidebar.proxy.badge.unconfirmed",
    title: "context.overview.capacityUnconfirmed",
    tone: "neutral",
  },
  outside: { label: "sidebar.proxy.badge.outside", title: "context.overview.outsidePool", tone: "neutral" },
  weeklyExhausted: {
    label: "sidebar.proxy.badge.weeklyExhausted",
    title: "sidebar.proxy.weeklyExhausted",
    tone: "danger",
  },
  fiveHourExhausted: {
    label: "sidebar.proxy.badge.fiveHourExhausted",
    title: "sidebar.proxy.fiveHourExhausted",
    tone: "warning",
  },
  noCapacity: { label: "sidebar.proxy.badge.noCapacity", title: "context.overview.noCapacity", tone: "warning" },
} as const

// Matches the meter thresholds so a percentage and its bar never disagree.
function quotaTone(value: number) {
  if (value < 10) return "danger" as const
  if (value < 30) return "warning" as const
  return "neutral" as const
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
    "flex w-full min-w-0 rounded-md px-0.5 text-start text-12-regular text-v2-text-text-muted focus-visible:outline-2 focus-visible:outline-border-active"
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
          class="w-[440px] max-w-[calc(100vw-24px)] [&_[data-slot=popover-body]]:max-h-[65vh] [&_[data-slot=popover-body]]:overflow-y-auto"
          triggerAs="button"
          triggerProps={{ type: "button", "aria-label": props.label, class: triggerClass }}
          trigger={props.trigger}
        >
          {props.children}
        </Popover>
      }
    >
      <Show
        when={props.open}
        fallback={
          <button type="button" aria-label={props.label} class={triggerClass} onClick={() => props.onOpenChange(true)}>
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

function QuotaMeter(props: {
  value: number | null
  label: string
  pace?: number | null
  paceLabel?: string
  class?: string
}) {
  return (
    <div
      role="meter"
      aria-label={props.label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={props.value ?? undefined}
      aria-description={props.paceLabel}
      title={props.paceLabel}
      class={`relative w-full rounded-full bg-v2-background-bg-layer-03 ${props.class ?? "h-1"}`}
    >
      <div
        class="h-full rounded-full transition-[width] duration-300 ease-out motion-reduce:transition-none"
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
          class="pointer-events-none absolute top-1/2 h-3 w-0.5 -translate-y-1/2 rounded-full bg-icon-critical-base"
          style={{ "inset-inline-start": `clamp(0px, calc(${props.pace}% - 1px), calc(100% - 2px))` }}
        />
      </Show>
    </div>
  )
}
