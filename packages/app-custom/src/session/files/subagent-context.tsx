import { createMemo, Show } from "solid-js"
import { Icon } from "@opencode/ui-custom/icon"
import { ProgressCircle } from "@opencode/ui-custom/progress-circle"
import { useData } from "@/runtime/server/current"
import { useLanguage } from "@/runtime/i18n/language"
import type { SubagentInfo } from "@/session/family"
import { latestContextMessage, measuredContext, subagentContext } from "./subagent-context-usage"

export function SubagentContext(props: { child: SubagentInfo }) {
  const data = useData()
  const language = useLanguage()
  const context = createMemo(() =>
    subagentContext(
      measuredContext(latestContextMessage(data.session.message.list(props.child.id)), props.child.context),
      data.location.model.list(props.child.location),
    ),
  )
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
        <Show when={context()?.usage != null}>
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
