import { Switch } from "@opencode/ui-custom/switch"
import { Tabs } from "@opencode/ui-custom/tabs"
import { getDirectory } from "@opencode/util/path"
import { createEffect, createMemo, createResource, For, Index, onCleanup, Show, type JSXElement } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { useMcpToggle } from "@/providers/connect/mcp"
import { useWorkspaceLocation } from "@/workspaces/location"
import { useData, useServer } from "@/runtime/server/current"
import { useServerSDK } from "@/runtime/server/client"
import { usePlatform } from "@/runtime/platform/platform"
import { pluginLabel } from "@/providers/catalog/plugin"
import { showToast } from "@/shell/notifications/toast"
import { configuredLanguageServers } from "@/settings/workspaces/project-lsp"
import { serviceStatus } from "./service-status"

type Service = "mcp" | "plugins" | "skills" | "lsp"

export function StatusPopoverBody(props: {
  shown: boolean
  embedded?: boolean
  compact?: boolean
  directory?: string
}) {
  const data = useData()
  const sdk = useWorkspaceLocation()
  const serverSDK = useServerSDK()
  const language = useLanguage()
  const directory = () => props.directory ?? sdk().directory
  const [state, setState] = createStore({ service: "" })

  const toggleMcp = useMcpToggle(directory)
  const [mcpLoad, mcpActions] = createResource(
    () => (props.shown ? directory() : undefined),
    async (location) => {
      data.location.mcp.server.invalidate({ directory: location })
      await data.location.mcp.server.sync({ directory: location })
    },
  )
  const mcpServers = createMemo(() =>
    (data.location.mcp.server.list({ directory: directory() }) ?? []).toSorted((a, b) => a.name.localeCompare(b.name)),
  )
  const mcpConnected = createMemo(() => mcpServers().filter((item) => item.status.status === "connected").length)
  const [pluginList, pluginActions] = createResource(
    () => (props.shown ? directory() : undefined),
    (location) => serverSDK.api.plugin.list({ location: { directory: location } }).then((result) => result.data),
  )
  const plugins = createMemo(() =>
    (pluginList.state === "errored" ? [] : (pluginList.latest ?? []))
      .filter((plugin) => plugin.source.type !== "builtin")
      .map((plugin) => ({
        name: pluginLabel(plugin),
        status: plugin.state.status,
        error: plugin.state.status === "failed" ? plugin.state.error : undefined,
      }))
      .toSorted((a, b) => a.name.localeCompare(b.name)),
  )
  const [skillList, skillActions] = createResource(
    () => (props.shown ? directory() : undefined),
    async (location) => {
      data.location.skill.invalidate({ directory: location })
      await data.location.skill.sync({ directory: location })
      return data.location.skill.list({ directory: location }) ?? []
    },
  )
  const skills = createMemo(() =>
    (skillList.state === "errored" ? [] : (skillList.latest ?? [])).toSorted((a, b) => a.name.localeCompare(b.name)),
  )
  const [configList, configActions] = createResource(
    () => (props.shown ? directory() : undefined),
    async (location) => {
      data.location.config.invalidate({ directory: location })
      await data.location.config.sync({ directory: location })
      return data.location.config.list({ directory: location }) ?? []
    },
  )
  const lsps = createMemo(() =>
    configuredLanguageServers(configList.state === "errored" ? [] : (configList.latest ?? [])),
  )

  createEffect(() => {
    const events = serverSDK.event.location(directory())
    const cleanups = [
      events.on("plugin.updated", () => void pluginActions.refetch()),
      events.on("skill.updated", () => void skillActions.refetch()),
      events.on("config.updated", () => void configActions.refetch()),
    ]
    onCleanup(() => cleanups.forEach((cleanup) => cleanup()))
  })

  const tabLabel = (count: number, key: "mcp" | "plugins" | "skills" | "lsp") =>
    `${count > 0 ? `${count} ` : ""}${language.t(`session.summary.${key}`)}`
  const status = (service: Service) => {
    if (service === "mcp")
      return serviceStatus(
        mcpServers().map((item) => item.status.status),
        mcpLoad.error,
      )
    if (service === "plugins")
      return serviceStatus(
        plugins().map((item) => item.status),
        pluginList.error,
      )
    if (service === "skills")
      return serviceStatus(
        skills().map(() => "active"),
        skillList.error,
      )
    return serviceStatus(
      lsps().servers.map((item) => (item.disabled ? "disabled" : "active")),
      configList.error,
    )
  }

  return (
    <div
      class="flex items-center gap-1 rounded-xl"
      classList={{
        "w-[360px] shadow-[var(--shadow-lg-border-base)]": !props.embedded,
        "w-full min-w-0": props.embedded,
      }}
    >
      <Tabs
        aria-label={language.t("status.popover.ariaLabel")}
        class={
          props.compact
            ? "tabs overflow-hidden w-full min-w-0"
            : "tabs bg-background-strong rounded-xl overflow-hidden w-full min-w-0"
        }
        data-active="mcp"
        defaultValue="mcp"
        value={props.compact ? state.service : undefined}
        activationMode={props.compact ? "manual" : "automatic"}
        variant="underline"
      >
        <Tabs.List
          data-slot="tablist"
          class={
            props.compact
              ? "bg-transparent !border-b-0 !px-2 !gap-2 !h-9 overflow-x-auto after:!hidden"
              : "bg-transparent border-b-0 px-4 pt-2 pb-0 gap-3 h-10 overflow-x-auto"
          }
        >
          <Show
            when={props.compact}
            fallback={
              <>
                <Tabs.Trigger value="mcp" data-slot="tab" class="text-12-regular shrink-0">
                  {tabLabel(mcpConnected(), "mcp")}
                </Tabs.Trigger>
                <Tabs.Trigger value="plugins" data-slot="tab" class="text-12-regular shrink-0">
                  {tabLabel(plugins().length, "plugins")}
                </Tabs.Trigger>
                <Tabs.Trigger value="skills" data-slot="tab" class="text-12-regular shrink-0">
                  {tabLabel(skills().length, "skills")}
                </Tabs.Trigger>
                <Tabs.Trigger value="lsp" data-slot="tab" class="text-12-regular shrink-0">
                  {tabLabel(lsps().servers.length, "lsp")}
                </Tabs.Trigger>
              </>
            }
          >
            <For each={["mcp", "plugins", "skills", "lsp"] as const}>
              {(service) => (
                <Tabs.Trigger
                  value={service}
                  data-slot="tab"
                  class="text-12-regular flex-1 min-w-0"
                  classes={{ button: "w-full flex items-center justify-center !gap-1 !px-1 !text-[12px]" }}
                  aria-expanded={state.service === service}
                  aria-description={language.t(`session.summary.service.${status(service)}`)}
                  title={language.t(`session.summary.service.${status(service)}`)}
                  onClick={() => setState("service", state.service === service ? "" : service)}
                  onKeyDown={(event) => {
                    if (event.key !== "Enter" && event.key !== " ") return
                    event.preventDefault()
                    setState("service", state.service === service ? "" : service)
                  }}
                >
                  <StatusDot status={status(service)} />
                  {language.t(`session.summary.${service}`)}
                </Tabs.Trigger>
              )}
            </For>
          </Show>
        </Tabs.List>

        <Tabs.Content value="mcp">
          <Panel>
            <ResourceState
              loading={mcpLoad.loading}
              ready={mcpLoad.state === "ready" || mcpLoad.state === "refreshing"}
              error={mcpLoad.error}
              retry={mcpActions.refetch}
            >
              <Show
                when={mcpServers().length > 0}
                fallback={
                  <Empty title={language.t("session.summary.mcp.empty")} directory={directory()} service="mcp" />
                }
              >
                <Index each={mcpServers()}>
                  {(item) => {
                    const name = () => item().name
                    const status = () => item().status.status
                    const error = () => {
                      const current = item().status
                      return current.status === "failed" ? current.error : undefined
                    }
                    const enabled = () => status() === "connected"
                    const pending = () => toggleMcp.isPending && toggleMcp.variables === name()
                    return (
                      <button
                        type="button"
                        class="flex items-center gap-2 w-full min-h-8 pl-3 pr-2 py-1 rounded-md hover:bg-surface-raised-base-hover transition-colors text-left"
                        title={error() ?? name()}
                        onClick={() => {
                          if (toggleMcp.isPending) return
                          toggleMcp.mutate(name())
                        }}
                        disabled={pending()}
                      >
                        <StatusDot status={status()} />
                        <span class="flex flex-col min-w-0 flex-1">
                          <span class="text-14-regular text-text-base truncate">{name()}</span>
                          <Show when={status() === "needs_auth"}>
                            <span class="text-11-regular text-text-weaker truncate">
                              {language.t("mcp.auth.clickToAuthenticate")}
                            </span>
                          </Show>
                        </span>
                        <div onClick={(event) => event.stopPropagation()}>
                          <Switch
                            appearance="standard"
                            checked={enabled()}
                            disabled={pending()}
                            onChange={() => {
                              if (toggleMcp.isPending) return
                              toggleMcp.mutate(name())
                            }}
                          />
                        </div>
                      </button>
                    )
                  }}
                </Index>
                <ConfigAction directory={directory()} service="mcp" />
              </Show>
            </ResourceState>
          </Panel>
        </Tabs.Content>

        <Tabs.Content value="plugins">
          <Panel>
            <ResourceState
              loading={pluginList.loading}
              ready={pluginList.state === "ready" || pluginList.state === "refreshing"}
              error={pluginList.error}
              retry={pluginActions.refetch}
            >
              <Show
                when={plugins().length > 0}
                fallback={
                  <Empty
                    title={language.t("session.summary.plugins.empty")}
                    directory={directory()}
                    service="plugins"
                  />
                }
              >
                <For each={plugins()}>
                  {(plugin) => (
                    <div class="flex items-center gap-2 w-full px-2 py-1" title={plugin.error ?? plugin.name}>
                      <StatusDot status={plugin.status} />
                      <span class="text-14-regular text-text-base truncate flex-1">{plugin.name}</span>
                      <Show when={plugin.status === "failed"}>
                        <span class="text-11-regular text-text-weaker">{language.t("session.summary.failed")}</span>
                      </Show>
                    </div>
                  )}
                </For>
                <ConfigAction directory={directory()} service="plugins" />
              </Show>
            </ResourceState>
          </Panel>
        </Tabs.Content>

        <Tabs.Content value="skills">
          <Panel>
            <ResourceState
              loading={skillList.loading}
              ready={skillList.state === "ready" || skillList.state === "refreshing"}
              error={skillList.error}
              retry={skillActions.refetch}
            >
              <Show
                when={skills().length > 0}
                fallback={
                  <Empty title={language.t("session.summary.skills.empty")} directory={directory()} service="skills" />
                }
              >
                <For each={skills()}>
                  {(skill) => (
                    <div class="flex items-center gap-2 w-full px-2 py-1">
                      <StatusDot status="active" />
                      <span class="text-14-regular text-text-base truncate">{skill.name}</span>
                    </div>
                  )}
                </For>
                <ConfigAction directory={directory()} service="skills" />
              </Show>
            </ResourceState>
          </Panel>
        </Tabs.Content>

        <Tabs.Content value="lsp">
          <Panel>
            <ResourceState
              loading={configList.loading}
              ready={configList.state === "ready" || configList.state === "refreshing"}
              error={configList.error}
              retry={configActions.refetch}
            >
              <Show
                when={!lsps().disabled}
                fallback={
                  <Empty
                    title={language.t("project.settings.extensions.lsp.disabled.title")}
                    description={language.t("project.settings.extensions.lsp.disabled.description")}
                    directory={directory()}
                    service="lsp"
                  />
                }
              >
                <Show
                  when={lsps().servers.length > 0}
                  fallback={
                    <Empty title={language.t("session.summary.lsp.empty")} directory={directory()} service="lsp" />
                  }
                >
                  <h3 class="px-2 pb-1 text-12-regular text-text-weaker">
                    {language.t("project.settings.extensions.lsp.configured")}
                  </h3>
                  <For each={lsps().servers}>
                    {(lsp) => (
                      <div class="flex items-center gap-2 w-full px-2 py-1">
                        <span class="text-14-regular text-text-base truncate flex-1">{lsp.name}</span>
                        <span class="text-11-regular text-text-weaker">
                          {language.t(
                            lsp.disabled
                              ? "project.settings.extensions.lsp.status.disabled"
                              : "project.settings.extensions.lsp.status.enabled",
                          )}
                        </span>
                      </div>
                    )}
                  </For>
                  <ConfigAction directory={directory()} service="lsp" />
                </Show>
              </Show>
            </ResourceState>
          </Panel>
        </Tabs.Content>
      </Tabs>
    </div>
  )
}

function Panel(props: { children: JSXElement }) {
  return (
    <div class="flex flex-col px-2 pb-2">
      <div class="flex flex-col p-3 bg-background-base rounded-sm min-h-14">{props.children}</div>
    </div>
  )
}

function ResourceState(props: {
  loading: boolean
  ready: boolean
  error: unknown
  retry: () => unknown
  children: JSXElement
}) {
  const language = useLanguage()
  return (
    <Show
      when={props.ready || !props.loading}
      fallback={
        <div class="text-14-regular text-text-base text-center my-auto" role="status">
          {language.t("common.loading")}
        </div>
      }
    >
      <Show
        when={!props.error}
        fallback={
          <div class="flex flex-col items-center gap-2 text-14-regular text-text-base text-center my-auto" role="alert">
            <span>{language.t("common.requestFailed")}</span>
            <button
              type="button"
              class="px-2 py-1 rounded-md hover:bg-surface-raised-base-hover"
              onClick={() => props.retry()}
            >
              {language.t("session.summary.retry")}
            </button>
          </div>
        }
      >
        {props.children}
      </Show>
    </Show>
  )
}

function StatusDot(props: { status: string }) {
  return (
    <span
      aria-hidden="true"
      classList={{
        "size-1.5 rounded-full shrink-0": true,
        "bg-icon-success-base": props.status === "connected" || props.status === "active",
        "bg-icon-critical-base": props.status === "failed",
        "bg-icon-warning-base": props.status === "needs_auth" || props.status === "pending",
        "bg-border-weak-base": props.status === "disabled",
      }}
    />
  )
}

function Empty(props: { title: string; description?: string; directory: string; service: Service }) {
  return (
    <div class="flex flex-col gap-2 text-14-regular text-text-base text-center my-auto">
      <span>{props.title}</span>
      <Show when={props.description}>
        <span class="text-12-regular text-text-weaker">{props.description}</span>
      </Show>
      <ConfigAction directory={props.directory} service={props.service} />
    </div>
  )
}

function ConfigAction(props: { directory: string; service: Service }) {
  const language = useLanguage()
  const platform = usePlatform()
  const server = useServer()
  const sdk = useServerSDK()
  const [state, setState] = createStore({ pending: false, copied: false })
  const reveal = () => server.isLocal && !!platform.revealPath
  const label = () => language.t(reveal() ? "session.summary.configure" : "session.summary.copyConfigPath")

  createEffect(() => {
    if (!state.copied) return
    const timeout = setTimeout(() => setState("copied", false), 2000)
    onCleanup(() => clearTimeout(timeout))
  })

  const activate = async () => {
    if (state.pending) return
    setState({ pending: true, copied: false })
    await sdk.api.config
      .get({ location: { directory: props.directory } })
      .then(async (entries) => {
        const documents = entries
          .filter((entry) => entry.type === "document")
          .filter((entry) => entry.path !== undefined && /\.jsonc?$/.test(entry.path))
        const path =
          documents.findLast((entry) => entry.info[props.service] !== undefined)?.path ?? documents.at(-1)?.path
        if (reveal()) {
          if (path && (await platform.revealPath!(path))) return
          await platform.openPath?.(path ? getDirectory(path) : props.directory)
          return
        }
        if (!path) throw new Error(language.t("session.summary.configFileMissing"))
        await (platform.writeClipboardText?.(path) ?? navigator.clipboard.writeText(path))
        setState("copied", true)
      })
      .catch((error: unknown) =>
        showToast({
          variant: "error",
          title: language.t("common.requestFailed"),
          description: error instanceof Error ? error.message : String(error),
        }),
      )
      .finally(() => setState("pending", false))
  }

  return (
    <button
      type="button"
      class="w-full mt-2 px-2 py-1 rounded-md text-12-regular text-v2-text-text-muted hover:bg-surface-raised-base-hover disabled:opacity-50"
      disabled={state.pending}
      title={state.copied ? language.t("common.copied") : label()}
      onClick={() => void activate()}
    >
      {state.copied ? language.t("common.copied") : label()}
    </button>
  )
}
