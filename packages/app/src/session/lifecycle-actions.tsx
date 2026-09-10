import type { SessionInfo } from "@opencode/client/promise"
import { Button } from "@opencode/ui/button"
import { useDialog } from "@opencode/ui/context/dialog"
import { Dialog, DialogFooter, DialogHeader, DialogTitleGroup } from "@opencode/ui/dialog"
import { useQueryClient } from "@tanstack/solid-query"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection, useServers } from "@/runtime/server/registry"
import { useGlobal } from "@/runtime/server/runtime"
import { errorMessage } from "@/shell/layout/helpers"
import { showToast } from "@/shell/notifications/toast"
import { notifySessionTabsRemoved } from "@/shell/titlebar/session-events"
import { removedSessionIDs } from "./session-domain"
import { sessionTitle } from "./title"

export function useSessionLifecycleActions() {
  const global = useGlobal()
  const servers = useServers()
  const queryClient = useQueryClient()
  const dialog = useDialog()
  const language = useLanguage()
  const [state, setState] = createStore({ pending: false })

  const run = async (server: ServerConnection.Key, session: SessionInfo, action: "archive" | "remove") => {
    if (state.pending) return false
    const conn = servers.list.find((item) => ServerConnection.key(item) === server)
    if (!conn) return false
    const ctx = global.ensureServerCtx(conn)
    const ids = removedSessionIDs(ctx.data.session.list(), session.id)
    setState("pending", true)
    return Promise.resolve()
      .then(() =>
        action === "archive"
          ? ctx.sdk.api.session.archive({ sessionID: session.id })
          : ctx.data.session.remove(session.id),
      )
      .then(async () => {
        if (action === "archive") {
          const archived = Date.now()
          ids.forEach((id) => {
            const current = ctx.data.session.get(id) ?? (id === session.id ? session : undefined)
            if (current) ctx.data.session.remember({ ...current, time: { ...current.time, archived } })
            ctx.data.session.invalidate(id)
          })
        }
        await queryClient.cancelQueries({ queryKey: ["home-sessions", conn], exact: true })
        queryClient.setQueryData<SessionInfo[]>(["home-sessions", conn], (current) =>
          current?.filter((item) => !ids.has(item.id)),
        )
        notifySessionTabsRemoved({ server, directory: session.location.directory, sessionIDs: [...ids] })
        void queryClient.invalidateQueries({ queryKey: ["home-sessions", conn], exact: true })
        return true
      })
      .catch((cause) => {
        showToast({
          variant: "error",
          title: language.t(action === "remove" ? "session.delete.failed.title" : "common.requestFailed"),
          description: errorMessage(cause, language.t("common.requestFailed")),
        })
        return false
      })
      .finally(() => setState("pending", false))
  }

  return {
    pending: () => state.pending,
    archive: async (server: ServerConnection.Key, session: SessionInfo) => {
      await run(server, session, "archive")
    },
    showDelete: (server: ServerConnection.Key, session: SessionInfo) =>
      dialog.show(() => <SessionDeleteDialog session={session} onConfirm={() => run(server, session, "remove")} />),
  }
}

export function SessionDeleteDialog(props: { session: SessionInfo; onConfirm: () => Promise<boolean> }) {
  const dialog = useDialog()
  const language = useLanguage()
  const [state, setState] = createStore({ pending: false })
  const confirm = async () => {
    if (state.pending) return
    setState("pending", true)
    const success = await props.onConfirm()
    setState("pending", false)
    if (success) dialog.close()
  }
  return (
    <Dialog fit>
      <DialogHeader hideClose>
        <DialogTitleGroup
          title={language.t("session.delete.title")}
          description={language.t("session.delete.confirmCascade", {
            name: sessionTitle(props.session.title) ?? language.t("command.session.new"),
          })}
        />
      </DialogHeader>
      <DialogFooter>
        <Button variant="ghost" disabled={state.pending} onClick={() => dialog.close()}>
          {language.t("common.cancel")}
        </Button>
        <Button variant="danger" disabled={state.pending} onClick={confirm}>
          {language.t("session.delete.button")}
        </Button>
      </DialogFooter>
    </Dialog>
  )
}
