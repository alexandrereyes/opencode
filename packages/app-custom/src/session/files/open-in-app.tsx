import { createEffect, createMemo } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { usePlatform } from "@/runtime/platform/platform"
import { Persist, persisted } from "@/runtime/persistence/storage"
import { showToast } from "@/shell/notifications/toast"
import { useServer } from "@/runtime/server/current"
import { Schema } from "effect"
import { Persistence } from "@/runtime/persistence/schema"
import { useServerSDK } from "@/runtime/server/client"
import { NativeApps } from "@opencode/plugin-app-custom/native-apps/rpc"
import { createNativeAppAvailability } from "./open-in-app-availability"

export const OPEN_APPS = [
  "vscode",
  "cursor",
  "zed",
  "textmate",
  "antigravity",
  "finder",
  "terminal",
  "iterm2",
  "ghostty",
  "warp",
  "xcode",
  "android-studio",
  "powershell",
  "sublime-text",
  "rider",
] as const

export type OpenApp = (typeof OPEN_APPS)[number]
export type OpenAppOS = "macos" | "windows" | "linux" | "unknown"

export const OpenAppPreferences = Persistence.struct({
  app: Schema.Literals(OPEN_APPS),
})

const appExistence = new Map<string, Promise<boolean>>()

export const MAC_OPEN_APPS = [
  {
    id: "vscode",
    label: "session.header.open.app.vscode",
    icon: "vscode",
    openWith: "Visual Studio Code",
  },
  { id: "cursor", label: "session.header.open.app.cursor", icon: "cursor", openWith: "Cursor" },
  { id: "zed", label: "session.header.open.app.zed", icon: "zed", openWith: "Zed" },
  { id: "rider", label: "session.header.open.app.rider", icon: "rider", openWith: "Rider" },
  { id: "textmate", label: "session.header.open.app.textmate", icon: "textmate", openWith: "TextMate" },
  {
    id: "antigravity",
    label: "session.header.open.app.antigravity",
    icon: "antigravity",
    openWith: "Antigravity",
  },
  { id: "terminal", label: "session.header.open.app.terminal", icon: "terminal", openWith: "Terminal" },
  { id: "iterm2", label: "session.header.open.app.iterm2", icon: "iterm2", openWith: "iTerm" },
  { id: "ghostty", label: "session.header.open.app.ghostty", icon: "ghostty", openWith: "Ghostty" },
  { id: "warp", label: "session.header.open.app.warp", icon: "warp", openWith: "Warp" },
  { id: "xcode", label: "session.header.open.app.xcode", icon: "xcode", openWith: "Xcode" },
  {
    id: "android-studio",
    label: "session.header.open.app.androidStudio",
    icon: "android-studio",
    openWith: "Android Studio",
  },
  {
    id: "sublime-text",
    label: "session.header.open.app.sublimeText",
    icon: "sublime-text",
    openWith: "Sublime Text",
  },
] as const

export const WINDOWS_OPEN_APPS = [
  { id: "vscode", label: "session.header.open.app.vscode", icon: "vscode", openWith: "code" },
  { id: "cursor", label: "session.header.open.app.cursor", icon: "cursor", openWith: "cursor" },
  { id: "zed", label: "session.header.open.app.zed", icon: "zed", openWith: "zed" },
  {
    id: "powershell",
    label: "session.header.open.app.powershell",
    icon: "powershell",
    openWith: "powershell",
  },
  {
    id: "sublime-text",
    label: "session.header.open.app.sublimeText",
    icon: "sublime-text",
    openWith: "Sublime Text",
  },
] as const

export const LINUX_OPEN_APPS = [
  { id: "vscode", label: "session.header.open.app.vscode", icon: "vscode", openWith: "code" },
  { id: "cursor", label: "session.header.open.app.cursor", icon: "cursor", openWith: "cursor" },
  { id: "zed", label: "session.header.open.app.zed", icon: "zed", openWith: "zed" },
  {
    id: "sublime-text",
    label: "session.header.open.app.sublimeText",
    icon: "sublime-text",
    openWith: "Sublime Text",
  },
] as const

export function detectOpenAppOS(platform: ReturnType<typeof usePlatform>): OpenAppOS {
  if (platform.platform === "desktop" && platform.os) return platform.os
  if (typeof navigator !== "object") return "unknown"
  const value = navigator.platform || navigator.userAgent
  if (/Mac/i.test(value)) return "macos"
  if (/Win/i.test(value)) return "windows"
  if (/Linux/i.test(value)) return "linux"
  return "unknown"
}

export function openAppsForOS(os: OpenAppOS) {
  if (os === "macos") return MAC_OPEN_APPS
  if (os === "windows") return WINDOWS_OPEN_APPS
  return LINUX_OPEN_APPS
}

const showRequestError = (language: ReturnType<typeof useLanguage>, err: unknown) => {
  showToast({
    variant: "error",
    title: language.t("common.requestFailed"),
    description: err instanceof Error ? err.message : String(err),
  })
}

export function useOpenInApp(input: { path: () => string }) {
  const platform = usePlatform()
  const server = useServer()
  const language = useLanguage()
  const sdk = useServerSDK()
  const nativeApps = createNativeAppAvailability({
    platform: () => platform.platform,
    local: () => server.isLocal,
    server: () => server.key,
    location: input.path,
    status: sdk.connection.status,
    list: (directory) => sdk.api.rpc(NativeApps.Definition).list({}, { location: { directory } }),
  })

  const os = createMemo(() =>
    platform.platform === "desktop" ? detectOpenAppOS(platform) : (nativeApps.value()?.os ?? "unknown"),
  )
  const apps = createMemo(() => openAppsForOS(os()).filter((app) => app.id === "vscode" || app.id === "rider"))

  const [exists, setExists] = createStore<Partial<Record<OpenApp, boolean>>>({})

  createEffect(() => {
    if (platform.platform !== "desktop") return
    if (!platform.checkAppExists) return

    const list = apps()

    setExists(Object.fromEntries(list.map((app) => [app.id, undefined])) as Partial<Record<OpenApp, boolean>>)

    void Promise.all(
      list.map((app) => checkAppExists(platform, app.openWith).then((ok) => [app.id, ok] as const)),
    ).then((entries) => {
      setExists(Object.fromEntries(entries) as Partial<Record<OpenApp, boolean>>)
    })
  })

  const options = createMemo(() => {
    const available = nativeApps.value()?.apps
    return apps()
      .filter((app) => (platform.platform === "desktop" ? exists[app.id] : available?.some((id) => id === app.id)))
      .map((app) => ({ ...app, label: language.t(app.label) }))
  })

  const [prefs, setPrefs] = persisted(Persist.global("open.app"), OpenAppPreferences, { app: "vscode" })
  const [menu, setMenu] = createStore({ open: false })
  const [openRequest, setOpenRequest] = createStore({
    app: undefined as OpenApp | undefined,
  })

  const canOpen = createMemo(
    () =>
      server.isLocal &&
      options().length > 0 &&
      (platform.platform === "desktop" ? !!platform.openPath : nativeApps.value()?.os === "macos"),
  )
  const current = createMemo(() => options().find((o) => o.id === prefs.app) ?? options().at(0))
  const opening = createMemo(() => openRequest.app !== undefined)

  const selectApp = (app: OpenApp | "finder") => {
    if (!options().some((item) => item.id === app)) return
    setPrefs("app", app)
  }

  const openPath = (app: OpenApp | "finder", target = input.path(), reveal = false) => {
    if (opening() || !canOpen()) return
    if (!target) return

    const item = options().find((o) => o.id === app)
    if (!item) return
    setOpenRequest("app", app)
    const request =
      platform.platform === "desktop"
        ? platform.openPath!(target, item.openWith)
        : sdk.api
            .rpc(NativeApps.Definition)
            .open({ app: item.id, path: target, reveal }, { location: { directory: input.path() } })
    request
      .catch((err: unknown) => {
        if (platform.platform === "desktop") return showRequestError(language, err)
        showToast({
          variant: "error",
          title: language.t("common.requestFailed"),
          description: language.t("session.header.open.failed", { app: item.label }),
        })
      })
      .finally(() => {
        setOpenRequest("app", undefined)
      })
  }

  const copyPath = (target = input.path()) => {
    if (!target) return
    navigator.clipboard
      .writeText(target)
      .then(() => {
        showToast({
          variant: "success",
          icon: "circle-check",
          title: language.t("common.copied"),
          description: target,
        })
      })
      .catch((err: unknown) => showRequestError(language, err))
  }

  return {
    canOpen,
    opening,
    current,
    options,
    menu,
    setMenu,
    openPath,
    selectApp,
    copyPath,
  }
}

function checkAppExists(platform: ReturnType<typeof usePlatform>, app: string) {
  const cached = appExistence.get(app)
  if (cached) return cached
  const request = Promise.resolve(platform.checkAppExists?.(app))
    .then(Boolean)
    .catch(() => false)
  appExistence.set(app, request)
  return request
}
