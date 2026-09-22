import { Show, type Accessor } from "solid-js"
import { Spinner } from "@opencode/ui-custom/spinner"
import type { RevertProgress } from "@/composer/state"
import { useLanguage } from "@/runtime/i18n/language"

export function SessionRevertStatus(props: { progress: Accessor<RevertProgress | undefined> }) {
  const language = useLanguage()
  return (
    <Show when={props.progress()}>
      {(progress) => (
        <div
          role="status"
          aria-live="polite"
          data-component="session-revert-status"
          class="flex items-center gap-2 py-2 text-12-regular text-v2-text-text-muted"
        >
          <Spinner class="size-4 shrink-0" />
          <span>
            {(() => {
              const value = progress()
              if (value.phase === "descendants")
                return language.plural("session.revert.subagents", value.total, { completed: value.completed })
              return language.t(`session.revert.${value.phase}`)
            })()}
          </span>
        </div>
      )}
    </Show>
  )
}
