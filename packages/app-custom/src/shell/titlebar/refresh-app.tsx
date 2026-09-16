import { Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Icon } from "@opencode/ui-custom/icon"
import { Spinner } from "@opencode/ui-custom/spinner"
import { useLanguage } from "@/runtime/i18n/language"
import { canRefreshApplication, refreshApplication } from "@/runtime/platform/service-worker"
import { showToast } from "@/shell/notifications/toast"

export function RefreshApp() {
  const language = useLanguage()
  const [state, setState] = createStore({ refreshing: false })
  if (!canRefreshApplication()) return

  const refresh = async () => {
    if (state.refreshing) return
    setState("refreshing", true)
    await refreshApplication().catch(() => {
      setState("refreshing", false)
      showToast({ variant: "error", title: language.t("common.requestFailed") })
    })
  }

  return (
    <button
      type="button"
      data-action="mobile-refresh-app"
      class="flex h-7 w-full shrink-0 items-center gap-2 rounded-[6px] px-2 text-[13px] leading-4 text-v2-text-text-faint hover:bg-v2-background-bg-layer-02 hover:text-v2-text-text-base focus-visible:outline-none focus-visible:bg-v2-background-bg-layer-02 disabled:pointer-events-none"
      disabled={state.refreshing}
      onClick={() => void refresh()}
    >
      <Show when={state.refreshing} fallback={<Icon name="refresh" size="small" />}>
        <Spinner class="size-3.5 shrink-0" />
      </Show>
      {language.t("titlebar.update")}
    </button>
  )
}
