import { createEffect, createMemo, createResource, onCleanup, Show } from "solid-js"
import type { SessionInfo, SessionMessageInfo } from "@opencode/client/promise"
import { Icon } from "@opencode/ui/icon"
import { ProgressCircle } from "@opencode/ui/progress-circle"
import { Spinner } from "@opencode/ui/spinner"
import { useData } from "@/runtime/server/current"
import { useServerSDK } from "@/runtime/server/client"
import { useLanguage } from "@/runtime/i18n/language"
import { latestContextMessage, subagentContext } from "./subagent-context-usage"

export function SubagentContext(props: { child: SessionInfo; active: boolean }) {
  const data = useData()
  const sdk = useServerSDK()
  const language = useLanguage()
  const cached = createMemo(() => latestContextMessage(data.session.message.list(props.child.id)))
  const request = createMemo(() => {
    if (!props.active || sdk.connection.status() !== "connected") return
    const controller = new AbortController()
    onCleanup(() => controller.abort())
    return { id: props.child.id, signal: controller.signal }
  })
  const [snapshot, { refetch, mutate }] = createResource(
    request,
    async (request, info): Promise<SessionMessageInfo | undefined> => {
      // A bounded assistant-only window avoids loading each child's transcript.
      const response = await sdk.api.message
        .list({ sessionID: request.id, type: "assistant", order: "desc", limit: 20 }, { signal: request.signal })
        .catch(() => undefined)
      return response ? latestContextMessage(response.data.toReversed()) : info.value
    },
  )
  onCleanup(
    sdk.event.on("session.revert.committed", (event) => {
      if (event.data.sessionID !== props.child.id) return
      mutate((value) => (value && value.id >= event.data.to ? undefined : value))
      if (props.active) void refetch()
    }),
  )
  // A step already running when the app connected may not have a cached row:
  // the data client drops its ending event rather than inventing its model.
  onCleanup(
    sdk.event.on("session.step.ended", (event) => {
      if (
        props.active &&
        event.data.sessionID === props.child.id &&
        !data.session.message.get(props.child.id, event.data.assistantMessageID)
      )
        void refetch()
    }),
  )
  onCleanup(
    sdk.event.on("session.step.failed", (event) => {
      if (
        props.active &&
        event.data.sessionID === props.child.id &&
        event.data.tokens &&
        !data.session.message.get(props.child.id, event.data.assistantMessageID)
      )
        void refetch()
    }),
  )
  createEffect(() => {
    if (!props.active || sdk.connection.status() !== "connected") return
    void data.location.model.sync(props.child.location).catch(() => undefined)
  })
  const context = createMemo(() => {
    // Never read a pending resource: optional metadata must not suspend the page.
    const fetched = snapshot.state === "ready" || snapshot.state === "refreshing" ? snapshot.latest : undefined
    const live = cached()
    return subagentContext(
      latestContextMessage([...(fetched ? [fetched] : []), ...(live ? [live] : [])]),
      data.location.model.list(props.child.location),
    )
  })
  return (
    <span
      data-slot="subagent-context"
      class="flex min-w-0 flex-wrap items-center gap-x-4 gap-y-2 text-12-regular text-v2-text-text-muted"
    >
      <span class="inline-flex min-w-0 items-center gap-1.5">
        <Icon name="subagent" size="small" class="shrink-0" />
        <bdi class="truncate" title={props.child.agent}>
          {props.child.agent ?? "—"}
        </bdi>
      </span>
      <span class="inline-flex items-center gap-1.5" aria-label={language.t("context.overview.context")}>
        <Show
          when={context()?.usage != null}
          fallback={
            <Show when={snapshot.loading && !context()}>
              <Spinner class="size-4" />
            </Show>
          }
        >
          <ProgressCircle
            appearance="indicator"
            size={16}
            strokeWidth={2}
            percentage={context()?.usage ?? 0}
            style={{
              "--progress-circle-background": "var(--v2-background-bg-layer-04, var(--border-weak-base))",
              "--progress-circle-background-overlay": "var(--v2-overlay-simple-overlay-pressed, transparent)",
              "--progress-circle-progress": "var(--v2-icon-icon-base, var(--icon-base))",
            }}
          />
        </Show>
        <bdi class="tabular-nums">
          <Show when={context()} fallback="—">
            {(value) => (
              <>
                {new Intl.NumberFormat(language.intl(), { notation: "compact", maximumFractionDigits: 1 }).format(
                  value().total,
                )}
                {value().usage != null
                  ? ` (${new Intl.NumberFormat(language.intl(), { style: "percent", maximumFractionDigits: 1 }).format((value().usage ?? 0) / 100)})`
                  : ""}
              </>
            )}
          </Show>
        </bdi>
      </span>
    </span>
  )
}
