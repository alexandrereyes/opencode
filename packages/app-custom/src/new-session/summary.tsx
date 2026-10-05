import type { Mcp } from "@opencode/schema/mcp"
import { createMemo, createResource, Index, Show } from "solid-js"
import { useLanguage } from "@/runtime/i18n/language"
import { useData } from "@/runtime/server/current"
import type { DraftMcpControls } from "./mcp"

/** One-click MCP toggles shown under the new-session composer. */
export function DraftMcpBar(props: { mcp: DraftMcpControls }) {
  const language = useLanguage()
  const data = useData()
  const [load, { refetch }] = createResource(
    () => props.mcp.directory(),
    async (directory) => {
      data.location.mcp.server.invalidate({ directory })
      await Promise.all([data.location.mcp.server.sync({ directory }), data.location.config.sync({ directory })])
    },
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
  // Order by the configured default, not the live state, so a chip never moves under the pointer.
  const servers = createMemo(() =>
    (data.location.mcp.server.list({ directory: props.mcp.directory() }) ?? []).toSorted(
      (a, b) =>
        Number(defaults()[b.name] ?? true) - Number(defaults()[a.name] ?? true) || a.name.localeCompare(b.name),
    ),
  )
  const checked = (name: string, status: Mcp.Status["status"]) =>
    props.mcp.controls.preview ? (props.mcp.controls.states[name] ?? defaults()[name] ?? true) : status !== "disabled"
  const pending = (status: Mcp.Status["status"]) =>
    props.mcp.controls.pending || (!props.mcp.controls.preview && status === "pending")
  const label = (status: Mcp.Status) => {
    if (props.mcp.controls.preview) return
    if (status.status === "failed") return status.error || language.t("session.summary.mcp.failed")
    if (status.status === "pending") return language.t("session.summary.mcp.connecting")
    if (status.status === "needs_auth") return language.t("session.summary.mcp.needsAuth")
  }

  return (
    <div
      data-component="new-session-mcp"
      role="group"
      aria-label={language.t("session.summary.mcp.title")}
      aria-busy={load.loading}
      class="flex min-h-7 min-w-0 flex-wrap items-center gap-1.5 px-0.5 pt-1.5"
    >
      <Show
        when={!load.error}
        fallback={
          <button
            type="button"
            class="flex h-7 items-center rounded-full px-2.5 text-[13px] leading-[var(--line-height-compact)] text-v2-state-fg-danger underline-offset-2 hover:underline"
            onClick={() => void refetch()}
          >
            {language.t("common.requestFailed")} · {language.t("session.summary.retry")}
          </button>
        }
      >
        <Show
          when={servers().length > 0}
          fallback={
            <span class="flex h-7 items-center text-[13px] leading-[var(--line-height-compact)] text-v2-text-text-faint">
              {language.t(load.loading ? "common.loading" : "session.summary.mcp.empty")}
            </span>
          }
        >
          <Index each={servers()}>
            {(server) => {
              const enabled = () => checked(server().name, server().status.status)
              const status = () => (props.mcp.controls.preview ? undefined : server().status.status)
              return (
                <button
                  type="button"
                  role="switch"
                  aria-checked={enabled()}
                  data-enabled={enabled()}
                  data-status={status()}
                  title={label(server().status) ?? server().name}
                  disabled={pending(server().status.status)}
                  class="group/mcp flex h-7 min-w-0 max-w-[220px] items-center gap-1.5 rounded-full border px-2.5 text-[13px] font-[440] leading-[var(--line-height-compact)] tracking-[-0.04px] transition-[background-color,border-color,color,opacity] duration-150 ease-in-out focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-v2-border-border-focus disabled:cursor-progress disabled:opacity-60 data-[enabled=true]:border-v2-border-border-base data-[enabled=true]:bg-v2-background-bg-layer-01 data-[enabled=true]:text-v2-text-text-base data-[enabled=true]:hover:bg-v2-overlay-simple-overlay-hover data-[enabled=false]:border-dashed data-[enabled=false]:border-v2-border-border-muted data-[enabled=false]:text-v2-text-text-faint data-[enabled=false]:hover:text-v2-text-text-muted"
                  onClick={() => props.mcp.controls.change(server().name, !enabled())}
                >
                  <span
                    aria-hidden="true"
                    classList={{
                      "size-1.5 shrink-0 rounded-full": true,
                      "bg-v2-border-border-muted": !enabled(),
                      "bg-v2-state-fg-success": enabled() && (status() === "connected" || status() === undefined),
                      "bg-v2-state-fg-danger": enabled() && status() === "failed",
                      "bg-v2-state-fg-warning": enabled() && status() === "needs_auth",
                      "bg-v2-icon-icon-muted animate-pulse": enabled() && status() === "pending",
                    }}
                  />
                  <span class="min-w-0 truncate">{server().name}</span>
                </button>
              )
            }}
          </Index>
        </Show>
      </Show>
      <Show when={props.mcp.controls.preview}>
        <span class="flex h-7 items-center text-[12px] leading-[var(--line-height-compact)] text-v2-text-text-faint">
          {language.t("session.summary.mcp.onCreation")}
        </span>
      </Show>
    </div>
  )
}
