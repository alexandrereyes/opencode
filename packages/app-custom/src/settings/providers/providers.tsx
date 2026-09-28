import { Button } from "@opencode/ui-custom/button"
import { Badge } from "@opencode/ui-custom/badge"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { Icon } from "@opencode/ui-custom/icon"
import { Menu } from "@opencode/ui-custom/menu"
import { ProviderIcon } from "@opencode/ui-custom/provider-icon"
import { showToast } from "@/shell/notifications/toast"
import { useProviders } from "@/providers/catalog/providers"
import { useIntegrations } from "@/providers/catalog/integrations"
import { createMemo, type Component, For, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { useServerSDK } from "@/runtime/server/client"
import { useData } from "@/runtime/server/current"
import { CONSOLE_INTEGRATION } from "@/providers/connect/controller"
import { DialogConnectProvider, useProviderConnectController } from "@/providers/connect/dialog"
import { SettingsServerScope } from "@/settings/server-scope"
import { InlineServerSelect } from "@/settings/server-select"
import { SettingsList } from "@/settings/list"
import "@/settings/settings.css"
import { popularConnections } from "./popular"
import { activeProviderAccount, providerAccounts, type ProviderAccount } from "./accounts"

type ProviderSource = "env" | "api" | "account" | "config" | "custom"
type ProviderItem = ReturnType<ReturnType<typeof useProviders>["connected"]>[number]

const PROVIDER_NOTES = [
  { match: (id: string) => id === "opencode", key: "dialog.provider.opencode.note" },
  { match: (id: string) => id === "opencode-go", key: "dialog.provider.opencodeGo.tagline" },
  { match: (id: string) => id === "anthropic", key: "dialog.provider.anthropic.note" },
  { match: (id: string) => id.startsWith("github-copilot"), key: "dialog.provider.copilot.note" },
  { match: (id: string) => id === "openai", key: "dialog.provider.openai.note" },
  { match: (id: string) => id === "google", key: "dialog.provider.google.note" },
  { match: (id: string) => id === "openrouter", key: "dialog.provider.openrouter.note" },
  { match: (id: string) => id === "vercel", key: "dialog.provider.vercel.note" },
] as const

const PROVIDER_ICON_SIZE = 16

export const SettingsProviders: Component<{
  directory: string | undefined
  onBack?: () => void
}> = (props) => {
  const dialog = useDialog()
  const language = useLanguage()
  const serverSdk = useServerSDK()
  const data = useData()
  const providers = useProviders(() => props.directory)
  const integrations = useIntegrations(() => props.directory)
  const providerConnect = useProviderConnectController({ onBack: props.onBack })
  const [state, setState] = createStore({ credentialID: undefined as string | undefined })
  const integration = (item: ProviderItem) =>
    integrations.list().find((entry) => entry.id === (item.integrationID ?? item.id))

  const connect = (provider?: string) => {
    providerConnect.select(provider)
    void dialog.show(() => (
      <SettingsServerScope directory={props.directory}>
        <DialogConnectProvider directory={props.directory} controller={providerConnect} />
      </SettingsServerScope>
    ))
  }

  const connected = createMemo(() => {
    return providers
      .connected()
      .filter(
        (provider) =>
          provider.id !== "opencode" || Object.values(provider.models).some((model) => model.cost.input > 0),
      )
      .toSorted((a, b) => Number(b.id === "opencode-go") - Number(a.id === "opencode-go"))
  })

  const popular = createMemo(() => {
    const connectedIDs = new Set(connected().map((p) => p.id))
    const console = integrations.list().find((entry) => entry.id === CONSOLE_INTEGRATION)
    return popularConnections(providers.popular(), connectedIDs, console)
  })

  // Connection state comes from the integration list like the TUI: credential
  // connections mean an API key or OAuth grant, env connections mean detected
  // environment variables, and a connectionless integration is config-provided.
  const source = (item: ProviderItem): ProviderSource | undefined => {
    const current = integration(item)
    const credential = current?.connections.find((connection) => connection.type === "credential")
    if (credential) return credential.method === "oauth" ? "account" : "api"
    if (current?.connections.some((connection) => connection.type === "env")) return "env"
    if (current) return "config"
    if (!("source" in item)) return
    const value = item.source
    if (value === "env" || value === "api" || value === "config" || value === "custom") return value
    return
  }

  const type = (item: ProviderItem) => {
    const current = source(item)
    if (current === "env") return language.t("settings.providers.tag.environment")
    if (current === "api") return language.t("provider.connect.method.apiKey")
    if (current === "account") return language.t("settings.providers.tag.account")
    if (current === "config") return language.t("settings.providers.tag.config")
    if (current === "custom") return language.t("settings.providers.tag.custom")
    return language.t("settings.providers.tag.other")
  }

  const canDisconnect = (item: ProviderItem) => {
    const current = integration(item)
    if (current) return current.connections.some((connection) => connection.type === "credential")
    const currentSource = source(item)
    return currentSource !== "env" && currentSource !== "config"
  }

  const canManageAccounts = (item: ProviderItem) => providerAccounts(integration(item)).length > 0

  const note = (id: string) => PROVIDER_NOTES.find((item) => item.match(id))?.key

  const disconnect = async (item: ProviderItem) => {
    const name = item.name
    const location = props.directory ? { directory: props.directory } : undefined
    await serverSdk.api.integration
      .get({ integrationID: item.integrationID ?? item.id, location })
      .then(async (integration) => {
        const credentials = integration.data?.connections.filter((item) => item.type === "credential") ?? []
        if (credentials.length === 0) throw new Error(`No removable credentials found for ${name}`)
        await Promise.all(
          credentials.map((credential) => serverSdk.api.credential.remove({ credentialID: credential.id })),
        )
        showToast({
          variant: "success",
          icon: "circle-check",
          title: language.t("provider.disconnect.toast.disconnected.title", { provider: name }),
          description: language.t("provider.disconnect.toast.disconnected.description", { provider: name }),
        })
      })
      .catch((err: unknown) => {
        const message = err instanceof Error ? err.message : String(err)
        showToast({ title: language.t("common.requestFailed"), description: message })
      })
  }

  const refreshAccounts = async () => {
    const location = props.directory ? { directory: props.directory } : undefined
    data.location.integration.invalidate(location)
    data.location.provider.invalidate(location)
    data.location.model.invalidate(location)
    await Promise.all([
      data.location.integration.sync(location),
      data.location.provider.sync(location),
      data.location.model.sync(location),
    ])
  }

  const accountError = (error: unknown) => {
    const message = error instanceof Error ? error.message : String(error)
    showToast({ title: language.t("common.requestFailed"), description: message })
  }

  const activate = async (item: ProviderItem, account: ProviderAccount) => {
    if (activeProviderAccount(integration(item))?.id === account.id) return
    setState("credentialID", account.id)
    await serverSdk.api.credential
      .activate({ credentialID: account.id })
      .then(refreshAccounts)
      .then(() =>
        showToast({
          variant: "success",
          icon: "circle-check",
          title: language.t("settings.providers.account.switched.title", { provider: item.name }),
          description: language.t("settings.providers.account.switched.description", { account: account.label }),
        }),
      )
      .catch(accountError)
      .finally(() => setState("credentialID", undefined))
  }

  const remove = async (item: ProviderItem, account: ProviderAccount) => {
    const final = providerAccounts(integration(item)).length === 1
    setState("credentialID", account.id)
    await serverSdk.api.credential
      .remove({ credentialID: account.id })
      .then(refreshAccounts)
      .then(() =>
        showToast({
          variant: "success",
          icon: "circle-check",
          title: final
            ? language.t("provider.disconnect.toast.disconnected.title", { provider: item.name })
            : language.t("settings.providers.account.removed.title", { account: account.label }),
          description: final
            ? language.t("provider.disconnect.toast.disconnected.description", { provider: item.name })
            : language.t("settings.providers.account.removed.description", { provider: item.name }),
        }),
      )
      .catch(accountError)
      .finally(() => setState("credentialID", undefined))
  }

  // A flat menu instead of upstream's removal submenu stays usable on touch screens.
  function AccountMenu(menuProps: { provider: ProviderItem }) {
    const accounts = () => providerAccounts(integration(menuProps.provider))
    const active = () => activeProviderAccount(integration(menuProps.provider))
    const busy = () => state.credentialID !== undefined

    return (
      <Menu placement="bottom-end" gutter={6} modal={false}>
        <Menu.Trigger
          as={Button}
          size="normal"
          variant="ghost-muted"
          class="settings-provider-account-trigger"
          aria-label={language.t("settings.providers.account.manage", { provider: menuProps.provider.name })}
        >
          <span>{active()?.label}</span>
          <Icon name="chevron-down" size="small" />
        </Menu.Trigger>
        <Menu.Portal>
          <Menu.Content class="settings-provider-account-menu">
            <Menu.Group>
              <Menu.GroupLabel>{language.t("settings.providers.account.group")}</Menu.GroupLabel>
              <Menu.RadioGroup
                value={active()?.id}
                onChange={(credentialID) => {
                  const account = accounts().find((item) => item.id === credentialID)
                  if (account) void activate(menuProps.provider, account)
                }}
              >
                <For each={accounts()}>
                  {(account) => (
                    <Menu.RadioItem value={account.id} closeOnSelect disabled={busy()}>
                      <span class="settings-provider-account-label">{account.label}</span>
                    </Menu.RadioItem>
                  )}
                </For>
              </Menu.RadioGroup>
            </Menu.Group>
            <Menu.Item disabled={busy()} onSelect={() => connect(menuProps.provider.id)}>
              {language.t("settings.providers.account.add")}
            </Menu.Item>
            <Menu.Separator />
            <Menu.Group>
              <Menu.GroupLabel>{language.t("settings.providers.account.removeGroup")}</Menu.GroupLabel>
              <For each={accounts()}>
                {(account) => (
                  <Menu.Item
                    disabled={busy()}
                    badge={account.id === active()?.id ? language.t("settings.providers.account.active") : undefined}
                    onSelect={() => void remove(menuProps.provider, account)}
                  >
                    <span class="settings-provider-account-label">{account.label}</span>
                  </Menu.Item>
                )}
              </For>
            </Menu.Group>
            <Menu.Separator />
            <Menu.Item disabled={busy()} onSelect={() => void disconnect(menuProps.provider)}>
              {language.t("settings.providers.account.disconnectAll")}
            </Menu.Item>
          </Menu.Content>
        </Menu.Portal>
      </Menu>
    )
  }

  return (
    <>
      <div class="settings-tab-header">
        <div class="settings-tab-header-row">
          <div class="flex flex-col gap-1">
            <h2 class="settings-tab-title">{language.t("settings.providers.title")}</h2>
            <span class="text-11-regular text-v2-text-text-muted">{language.t("settings.providers.description")}</span>
          </div>
          <InlineServerSelect />
        </div>
      </div>

      <div class="settings-tab-body settings-providers">
        <div class="settings-section" data-component="connected-providers-section">
          <h3 class="settings-section-title">{language.t("settings.providers.section.connected")}</h3>
          <SettingsList>
            <Show
              when={connected().length > 0}
              fallback={<div class="settings-provider-empty">{language.t("settings.providers.connected.empty")}</div>}
            >
              <For each={connected()}>
                {(item) => (
                  <div class="settings-provider-row group">
                    <div class="settings-provider-lead">
                      <ProviderIcon
                        id={item.id}
                        width={PROVIDER_ICON_SIZE}
                        height={PROVIDER_ICON_SIZE}
                        class="settings-provider-icon shrink-0"
                      />
                      <div class="settings-provider-main">
                        <span class="settings-provider-name truncate">{item.name}</span>
                        <Badge>{type(item)}</Badge>
                      </div>
                    </div>
                    <Show
                      when={canManageAccounts(item)}
                      fallback={
                        <Show
                          when={canDisconnect(item)}
                          fallback={
                            <span class="settings-provider-env-hint">
                              {language.t("settings.providers.connected.environmentDescription")}
                            </span>
                          }
                        >
                          <Button size="normal" variant="ghost-muted" onClick={() => void disconnect(item)}>
                            {language.t("common.disconnect")}
                          </Button>
                        </Show>
                      }
                    >
                      <AccountMenu provider={item} />
                    </Show>
                  </div>
                )}
              </For>
            </Show>
          </SettingsList>
        </div>

        <div class="settings-section">
          <h3 class="settings-section-title">{language.t("settings.providers.section.popular")}</h3>
          <SettingsList>
            <For each={popular()}>
              {(item) => (
                <div class="settings-provider-row">
                  <div class="settings-provider-lead">
                    <ProviderIcon
                      id={item.id}
                      width={PROVIDER_ICON_SIZE}
                      height={PROVIDER_ICON_SIZE}
                      class="settings-provider-icon shrink-0"
                    />
                    <div class="settings-provider-copy">
                      <div class="settings-provider-main">
                        <span class="settings-provider-name">{item.name}</span>
                        <Show when={item.id === "opencode" || item.id === "opencode-go"}>
                          <Badge>{language.t("dialog.provider.tag.recommended")}</Badge>
                        </Show>
                      </div>
                      <Show when={note(item.id)}>
                        {(key) => <p class="settings-provider-description">{language.t(key())}</p>}
                      </Show>
                    </div>
                  </div>
                  <Button size="normal" variant="neutral" icon="plus" onClick={() => connect(item.id)}>
                    {language.t("common.connect")}
                  </Button>
                </div>
              )}
            </For>
          </SettingsList>

          <button type="button" class="settings-providers-view-all" onClick={() => connect()}>
            {language.t("dialog.provider.viewAll")}
          </button>
        </div>
      </div>
    </>
  )
}
