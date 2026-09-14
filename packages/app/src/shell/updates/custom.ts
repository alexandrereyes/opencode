import { createStore } from "solid-js/store"
import { createEffect, createMemo, on, onCleanup, onMount } from "solid-js"
import { Updates } from "@opencode/plugin-app-custom/updates/rpc"
import { createApiForServer, type ServerApi } from "@/runtime/server/api"
import { useServers, type ServerConnection } from "@/runtime/server/registry"
import type { UpdaterPlatform, UpdaterState } from "./types"
import { waitForRelease } from "@opencode/plugin-app-custom/updates/client"
import { useLanguage } from "@/runtime/i18n/language"
import { formatServerError } from "@/runtime/server/errors"

/** The distribution serving this page, not a different server selected in a tab. */
export function CustomUpdater(props: { server: ServerConnection.HttpBase; ready: (updater: UpdaterPlatform) => void }) {
  const servers = useServers()
  const client = createMemo(() =>
    createApiForServer({
      server: servers.list.find((server) => server.http.url === props.server.url)?.http ?? props.server,
    }),
  )
  props.ready(createCustomUpdater(client))
  return null
}

export function createCustomUpdater(client: () => ServerApi): UpdaterPlatform {
  const language = useLanguage()
  const [store, setStore] = createStore<{ state: UpdaterState; target?: Updates.Target }>({
    state: { status: "idle" },
  })
  const controller = new AbortController()
  const restart = async (version: string) => {
    await waitForRelease(client(), version, AbortSignal.any([controller.signal, AbortSignal.timeout(120_000)]))
    window.location.reload()
  }
  const failed = (error: unknown) => {
    const state = {
      status: "error" as const,
      message: formatServerError(error, language.t, language.t("common.requestFailed")),
    }
    setStore("state", state)
    return state
  }
  let pending: Promise<UpdaterState> | undefined
  const check = () => {
    if (store.state.status === "installing") return Promise.resolve(store.state)
    if (pending) return pending
    setStore("state", { status: "checking" })
    pending = client()
      .rpc(Updates.Definition)
      .check({}, { signal: controller.signal })
      .then((state) => {
        setStore("target", state.status === "ready" ? { commit: state.commit, version: state.version } : undefined)
        setStore("state", state)
        if (state.status === "installing") void restart(state.version).catch(failed)
        return state
      })
      .catch(failed)
      .finally(() => {
        pending = undefined
      })
    return pending
  }
  createEffect(
    on(client, () => {
      if (pending) void pending.then(() => check())
      if (!pending) void check()
    }),
  )
  onMount(() => {
    const timer = setInterval(() => void check(), 60_000)
    onCleanup(() => clearInterval(timer))
  })
  onCleanup(() => controller.abort())
  return {
    state: () => store.state,
    check,
    async install() {
      const target = store.target
      if (!target || store.state.status !== "ready") return
      setStore("state", { status: "installing", version: target.version })
      await client()
        .rpc(Updates.Definition)
        .install(target)
        .then(() => restart(target.version))
        .catch(failed)
    },
  }
}
