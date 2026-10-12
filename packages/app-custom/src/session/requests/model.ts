import { createEffect, createMemo, untrack } from "solid-js"
import { createStore } from "solid-js/store"
import type { FormInfo, PermissionRequest } from "@opencode/client/promise"
import { useParams } from "@solidjs/router"
import { showToast } from "@/shell/notifications/toast"
import { useServerSDK } from "@/runtime/server/client"
import { useLanguage } from "@/runtime/i18n/language"
import { useSettings } from "@/settings/model"
import { useWorkspaceLocation } from "@/workspaces/location"
import { createWebSearchRequest } from "./websearch"
import { createSessionBackground } from "@/session/requests/background"
import { useServer, useData } from "@/runtime/server/current"
import { syncSessionBackgroundShells } from "./background-shells"

export function createSessionRequestModel() {
  const params = useParams()
  const sdk = useWorkspaceLocation()
  const serverSDK = useServerSDK()
  const data = useData()
  const language = useLanguage()
  const settings = useSettings()
  const families = useServer().ctx.families
  families.watch(() => params.id)
  // Inside a subagent, running work is the parent's, so the header lists its siblings.
  const owner = createMemo(() => {
    const id = params.id
    if (!id) return
    return data.session.get(id)?.parentID ?? id
  })
  createEffect(() => {
    const id = params.id
    const parent = owner()
    if (!id || !parent || serverSDK.connection.status() !== "connected") return
    new Set([id, parent]).forEach(
      (sessionID) =>
        void syncSessionBackgroundShells({
          sessionID,
          current: sdk().ref,
          known: untrack(() => data.shell.listBySession(sessionID).map((shell) => shell.location)),
          message: serverSDK.api.message,
          sync: (location) => data.shell.sync(location),
        }).catch(() => undefined),
    )
  })
  const formRequest = createMemo((): FormInfo | undefined => families.get(params.id)?.snapshot?.forms[0])
  const websearch = createWebSearchRequest({
    owner: () => params.id,
    connected: () => serverSDK.connection.status() === "connected",
    request: () => {
      const form = formRequest()
      return form?.metadata?.kind === "websearch.provider" ? form : undefined
    },
    providers: async (sessionID) => {
      const session = data.session.get(sessionID) ?? (await serverSDK.api.session.get({ sessionID }))
      const result = await serverSDK.api.websearch.providers({
        location: { directory: session.location.directory },
      })
      return result.data.map((provider) => ({ value: provider.id, label: provider.name }))
    },
    reply: (input) => data.session.form.reply(input),
    events: serverSDK.event,
  })
  const questionRequest = createMemo(() => {
    if (websearch.request()) return
    const form = formRequest()
    return form?.metadata?.kind === "question" ? form : undefined
  })

  const permissionRequest = createMemo((): PermissionRequest | undefined => {
    if (settings.permissions.autoApprove()) return undefined
    return families.get(params.id)?.snapshot?.permissions[0]
  })

  const blocked = createMemo(() => {
    const id = params.id
    if (!id) return false
    return !!permissionRequest() || !!questionRequest() || !!websearch.request()
  })

  const primary = () => {
    const id = params.id
    return !!id && !data.session.get(id)?.parentID
  }
  const running = createSessionBackground({
    sessionID: owner,
    messages: data.session.message.list,
    sessions: data.session.list,
    status: data.session.status,
    shells: () => {
      const id = owner()
      return id ? data.shell.listBySession(id) : []
    },
  })
  createEffect(() => {
    if (serverSDK.connection.status() !== "connected") return
    running.unresolved().forEach((sessionID) => void data.session.sync(sessionID).catch(() => undefined))
  })
  // A subagent opened directly has not loaded its parent's turn or its siblings.
  createEffect(() => {
    const id = owner()
    if (!id || id === params.id || serverSDK.connection.status() !== "connected") return
    void data.session.sync(id, { children: true }).catch(() => undefined)
  })
  // Moving to the background and the summary's background list stay with the primary session's own work.
  const blocking = createMemo(() => (primary() ? running.blocking() : []))
  const tasks = createMemo(() => (primary() ? running.tasks() : []))
  const moveToBackground = async () => {
    if (!primary()) return
    const sessionID = params.id
    if (!sessionID) return
    await serverSDK.api.session.background({ sessionID }).catch((error) => {
      showToast({
        title: language.t("common.requestFailed"),
        description: error instanceof Error ? error.message : String(error),
      })
    })
  }

  const [store, setStore] = createStore({
    responding: undefined as string | undefined,
  })

  const permissionResponding = createMemo(() => {
    const perm = permissionRequest()
    if (!perm) return false
    return store.responding === perm.id
  })

  const decide = (response: "once" | "always" | "reject") => {
    const perm = permissionRequest()
    if (!perm) return
    if (store.responding === perm.id) return

    setStore("responding", perm.id)
    serverSDK.api.permission
      .reply({ sessionID: perm.sessionID, requestID: perm.id, decision: response })
      .catch((err: unknown) => {
        const description = err instanceof Error ? err.message : String(err)
        showToast({ title: language.t("common.requestFailed"), description })
      })
      .finally(() => {
        setStore("responding", (id) => (id === perm.id ? undefined : id))
      })
  }

  return {
    blocked,
    pendingFailed: () => !!families.get(params.id)?.failed,
    retryPending: () => {
      if (params.id) families.retry(params.id)
    },
    questionRequest,
    websearch,
    permissionRequest,
    permissionResponding,
    background: {
      blocking,
      tasks,
      running: { sessionID: owner, blocking: running.blocking, tasks: running.tasks },
      move: moveToBackground,
    },
    decide,
  }
}

export type SessionRequestModel = ReturnType<typeof createSessionRequestModel>
