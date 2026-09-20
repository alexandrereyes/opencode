import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { Popover } from "@opencode/ui-custom/popover"
import { Switch } from "@opencode/ui-custom/switch"
import type { Mcp } from "@opencode/schema/mcp"
import { createMemo, createResource, Index, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { useData } from "@/runtime/server/current"
import type { DraftMcpControls } from "./mcp"

export function DraftMcpPicker(props: { mcp: DraftMcpControls }) {
  const language = useLanguage()
  const data = useData()
  const [store, setStore] = createStore({ open: false })
  const [load, { refetch }] = createResource(
    () => store.open && ([props.mcp.directory(), props.mcp.controls.preview] as const),
    async ([directory, preview]) => {
      data.location.mcp.server.invalidate({ directory })
      await Promise.all([
        data.location.mcp.server.sync({ directory }),
        ...(preview ? [data.location.config.sync({ directory })] : []),
      ])
    },
  )
  const servers = createMemo(() =>
    (data.location.mcp.server.list({ directory: props.mcp.directory() }) ?? []).toSorted((a, b) =>
      a.name.localeCompare(b.name),
    ),
  )
  const defaults = createMemo(() =>
    Object.fromEntries(
      (data.location.config.list({ directory: props.mcp.directory() }) ?? []).flatMap((entry) =>
        entry.type === "document"
          ? Object.entries(entry.info.mcp?.servers ?? {}).map(([name, config]) => [name, !config.disabled] as const)
          : [],
      ),
    ),
  )
  const checked = (name: string, status: Mcp.Status["status"]) =>
    props.mcp.controls.preview ? (props.mcp.controls.states[name] ?? defaults()[name] ?? true) : status !== "disabled"
  const pending = (status: Mcp.Status["status"]) =>
    props.mcp.controls.pending || (!props.mcp.controls.preview && status === "pending")
  const label = (status: Mcp.Status["status"]) => {
    if (props.mcp.controls.preview) return
    if (status === "failed") return language.t("session.summary.mcp.failed")
    if (status === "pending") return language.t("session.summary.mcp.connecting")
    if (status === "needs_auth") return language.t("session.summary.mcp.needsAuth")
  }
  const error = (status: Mcp.Status) => (status.status === "failed" ? status.error : undefined)

  return (
    <Popover
      open={store.open}
      onOpenChange={(open) => setStore("open", open)}
      placement="bottom-end"
      gutter={4}
      class="[&_[data-slot=popover-body]]:p-0 w-[320px] max-w-[calc(100vw-40px)] rounded-xl border-0 bg-transparent shadow-none"
      triggerAs={IconButton}
      triggerProps={{
        variant: "ghost-muted",
        size: "large",
        class: "!w-9 shrink-0",
        state: store.open ? "pressed" : undefined,
        "aria-label": language.t("session.summary.mcp.title"),
      }}
      trigger={<Icon name="mcp" />}
    >
      <div
        role="dialog"
        aria-label={language.t("session.summary.mcp.title")}
        dir={language.direction()}
        class="w-[320px] max-w-[calc(100vw-40px)] rounded-xl bg-background-strong p-2 shadow-[var(--shadow-lg-border-base)]"
      >
        <div class="px-2 pb-2 pt-1 text-13-medium leading-[var(--line-height-compact)] text-text-base">
          {language.t("session.summary.mcp.title")}
        </div>
        <Show when={props.mcp.controls.preview}>
          <div class="px-2 pb-2 text-12-regular text-text-weaker">{language.t("session.summary.mcp.onCreation")}</div>
        </Show>
        <div class="flex min-h-14 flex-col rounded-sm bg-background-base p-1" aria-busy={load.loading}>
          <Show
            when={!load.error}
            fallback={
              <div
                class="my-auto flex flex-col items-center gap-1 px-2 text-center text-13-regular leading-[var(--line-height-compact)] text-text-base"
                role="alert"
              >
                <span>{language.t("common.requestFailed")}</span>
                <button type="button" class="underline" onClick={() => void refetch()}>
                  {language.t("session.summary.retry")}
                </button>
              </div>
            }
          >
            <Show
              when={!load.loading || servers().length > 0}
              fallback={
                <div class="my-auto px-2 text-center text-13-regular text-text-base" role="status">
                  {language.t("common.loading")}
                </div>
              }
            >
              <Show
                when={servers().length > 0}
                fallback={
                  <div class="my-auto px-2 text-center text-13-regular leading-[var(--line-height-compact)] text-text-base">
                    {language.t("session.summary.mcp.empty")}
                  </div>
                }
              >
                <Index each={servers()}>
                  {(server) => (
                    <button
                      type="button"
                      title={error(server().status) ?? server().name}
                      class="flex min-h-8 w-full items-center gap-2 rounded-md px-2 py-1 text-left transition-colors hover:bg-surface-raised-base-hover disabled:opacity-60"
                      disabled={pending(server().status.status)}
                      onClick={() =>
                        props.mcp.controls.change(server().name, !checked(server().name, server().status.status))
                      }
                    >
                      <span
                        classList={{
                          "size-1.5 shrink-0 rounded-full": true,
                          "bg-icon-success-base": server().status.status === "connected",
                          "bg-icon-critical-base": server().status.status === "failed",
                          "bg-border-weak-base": server().status.status === "disabled",
                          "bg-icon-warning-base": server().status.status === "needs_auth",
                        }}
                        aria-hidden="true"
                      />
                      <span class="min-w-0 flex-1 truncate text-14-regular text-text-base">{server().name}</span>
                      <Show when={label(server().status.status)}>
                        {(value) => <span class="text-11-regular text-text-weaker">{value()}</span>}
                      </Show>
                      <span onClick={(event) => event.stopPropagation()}>
                        <Switch
                          appearance="standard"
                          checked={checked(server().name, server().status.status)}
                          disabled={pending(server().status.status)}
                          onChange={(enabled) => props.mcp.controls.change(server().name, enabled)}
                        />
                      </span>
                    </button>
                  )}
                </Index>
              </Show>
            </Show>
          </Show>
        </div>
      </div>
    </Popover>
  )
}
