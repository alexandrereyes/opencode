import type { SessionInfo } from "@opencode/client/promise"
import { Button } from "@opencode/ui/button"
import { useDialog } from "@opencode/ui/context/dialog"
import { Dialog, DialogBody, DialogFooter, DialogHeader, DialogTitleGroup } from "@opencode/ui/dialog"
import { useQueryClient } from "@tanstack/solid-query"
import { createMemo, For } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection, useServers } from "@/runtime/server/registry"
import { useGlobal } from "@/runtime/server/runtime"
import { errorMessage } from "@/shell/layout/helpers"
import { showToast } from "@/shell/notifications/toast"
import { notifySessionTabsRemoved } from "@/shell/titlebar/session-events"
import { removedSessionIDs } from "./session-domain"
import { sessionTitle } from "./title"

export type SessionLifecycleTarget = { server: ServerConnection.Key; session: SessionInfo }
export type SessionLifecycleResult = {
  succeeded: SessionLifecycleTarget[]
  failed: (SessionLifecycleTarget & { error: string })[]
}

export function useSessionLifecycleActions() {
  const global = useGlobal()
  const servers = useServers()
  const queryClient = useQueryClient()
  const dialog = useDialog()
  const language = useLanguage()
  const [state, setState] = createStore({ pending: false })

  const perform = async (
    { server, session }: SessionLifecycleTarget,
    action: "archive" | "remove",
    ids: Set<string>,
  ) => {
    const conn = servers.list.find((item) => ServerConnection.key(item) === server)
    if (!conn) throw new Error(language.t("session.bulk.unavailable"))
    const ctx = global.ensureServerCtx(conn)
    if (ctx.sdk.connection.status() !== "connected") throw new Error(language.t("session.bulk.unavailable"))
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
      })
  }

  const run = async (input: readonly SessionLifecycleTarget[], action: "archive" | "remove", bulk = false) => {
    if (state.pending) return undefined
    setState("pending", true)
    const result: SessionLifecycleResult = { succeeded: [], failed: [] }
    // Include submitted snapshots: a selected descendant need not have reached the local cache yet.
    const targets = [...new Map(input.map((item) => [JSON.stringify([item.server, item.session.id]), item])).values()]
    const groups = [...Map.groupBy(targets, (item) => item.server)].flatMap(([server, items]) => {
      const conn = servers.list.find((item) => ServerConnection.key(item) === server)
      const sessions = [
        ...(conn ? global.ensureServerCtx(conn).data.session.list() : []),
        ...items.map((item) => item.session),
      ]
      const trees = items.map((target) => ({ target, ids: removedSessionIDs(sessions, target.session.id) }))
      return trees
        .filter((tree) => !trees.some((parent) => parent !== tree && parent.ids.has(tree.target.session.id)))
        .map((tree) => ({ ...tree, targets: items.filter((item) => tree.ids.has(item.session.id)) }))
    })
    // Serial mutations keep the shared service bounded and do not retry failed requests.
    for (const group of groups) {
      await perform(group.target, action, group.ids).then(
        () => result.succeeded.push(...group.targets),
        (cause) =>
          result.failed.push(
            ...group.targets.map((target) => ({
              ...target,
              error: errorMessage(cause, language.t("common.requestFailed")),
            })),
          ),
      )
    }
    setState("pending", false)
    if (result.failed.length) {
      showToast({
        variant: "error",
        title: bulk
          ? language.plural("session.bulk.failed", result.failed.length, { succeeded: result.succeeded.length })
          : language.t(action === "remove" ? "session.delete.failed.title" : "common.requestFailed"),
        description: [...new Set(result.failed.map((item) => item.error))].join("\n"),
      })
    }
    return result
  }

  return {
    pending: () => state.pending,
    archive: async (server: ServerConnection.Key, session: SessionInfo) => {
      await run([{ server, session }], "archive")
    },
    showDelete: (server: ServerConnection.Key, session: SessionInfo) =>
      dialog.show(() => (
        <SessionDeleteDialog
          session={session}
          onConfirm={async () => {
            const result = await run([{ server, session }], "remove")
            return !!result && !result.failed.length
          }}
        />
      )),
    archiveMany: async (
      targets: readonly SessionLifecycleTarget[],
      onComplete: (result: SessionLifecycleResult) => void,
    ) => {
      const result = await run(targets, "archive", true)
      if (result) onComplete(result)
      return result
    },
    showDeleteMany: (
      targets: () => readonly SessionLifecycleTarget[],
      onComplete: (result: SessionLifecycleResult) => void,
    ) => {
      if (!targets().length || state.pending) return
      void dialog.show(() => {
        const unique = createMemo(() => [
          ...new Map(targets().map((item) => [JSON.stringify([item.server, item.session.id]), item])).values(),
        ])
        return (
          <SessionBulkDeleteDialog
            targets={unique()}
            onConfirm={async () => {
              const result = await run(unique(), "remove", true)
              if (result) onComplete(result)
              return !!result
            }}
          />
        )
      })
    },
  }
}

function SessionBulkDeleteDialog(props: { targets: SessionLifecycleTarget[]; onConfirm: () => Promise<boolean> }) {
  const dialog = useDialog()
  const language = useLanguage()
  const [state, setState] = createStore({ pending: false, submitted: [] as SessionLifecycleTarget[] })
  const targets = () => (state.pending ? state.submitted : props.targets)
  const confirm = async () => {
    if (state.pending) return
    const active = dialog.active
    setState({ pending: true, submitted: props.targets })
    const completed = await props.onConfirm()
    setState("pending", false)
    if (completed && dialog.active === active) dialog.close()
  }
  return (
    <Dialog fit>
      <DialogHeader hideClose>
        <DialogTitleGroup
          title={language.plural("session.bulk.delete.title", targets().length)}
          description={language.plural("session.bulk.delete.confirm", targets().length)}
        />
      </DialogHeader>
      <DialogBody class="min-w-0 px-4 pb-2">
        <ul class="max-h-48 overflow-y-auto text-[13px] leading-4 text-v2-text-text-base">
          <For each={targets()}>
            {(target) => (
              <li dir="auto" class="break-words">
                {sessionTitle(target.session.title) ?? language.t("command.session.new")}
              </li>
            )}
          </For>
        </ul>
      </DialogBody>
      <DialogFooter>
        <Button variant="ghost" disabled={state.pending} onClick={() => dialog.close()}>
          {language.t("common.cancel")}
        </Button>
        <Button variant="danger" disabled={state.pending || !props.targets.length} onClick={confirm}>
          {state.pending
            ? language.t("session.bulk.delete.pending")
            : language.plural("session.bulk.delete.title", props.targets.length)}
        </Button>
      </DialogFooter>
    </Dialog>
  )
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
