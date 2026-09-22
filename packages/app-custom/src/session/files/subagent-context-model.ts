import { createEffect, createMemo, createResource, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import type { SessionInfo, SessionMessageInfo } from "@opencode/client/promise"
import type { ServerSDK } from "@/runtime/server/client"
import type { ServerCtx } from "@/runtime/server/runtime"
import { latestContextMessage } from "./subagent-context-usage"

export function createSubagentContextSnapshot(input: {
  child: () => SessionInfo
  active: () => boolean
  sdk: {
    api: { message: Pick<ServerSDK["api"]["message"], "list"> }
    event: Pick<ServerSDK["event"], "on">
    connection: Pick<ServerSDK["connection"], "status" | "epoch">
  }
  data: {
    session: { message: Pick<ServerCtx["data"]["session"]["message"], "get"> }
    location: { model: Pick<ServerCtx["data"]["location"]["model"], "sync"> }
  }
}) {
  const [state, setState] = createStore({ revision: 0 })
  const request = createMemo(() => {
    if (!input.active() || input.sdk.connection.status() !== "connected") return
    const controller = new AbortController()
    onCleanup(() => controller.abort())
    return {
      id: input.child().id,
      signal: controller.signal,
      epoch: input.sdk.connection.epoch(),
      revision: state.revision,
    }
  })
  const [snapshot, { mutate }] = createResource(
    request,
    async (
      request,
      info,
    ): Promise<{ id: string; epoch: number; revision: number; message?: SessionMessageInfo } | undefined> => {
      if (
        info.value?.id === request.id &&
        info.value.epoch === request.epoch &&
        info.value.revision === request.revision
      )
        return info.value
      // A bounded assistant-only window avoids loading each child's transcript.
      const response = await input.sdk.api.message
        .list({ sessionID: request.id, type: "assistant", order: "desc", limit: 20 }, { signal: request.signal })
        .catch(() => undefined)
      return response && !request.signal.aborted
        ? {
            id: request.id,
            epoch: request.epoch,
            revision: request.revision,
            message: latestContextMessage(response.data.toReversed()),
          }
        : info.value
    },
  )
  onCleanup(
    input.sdk.event.on("session.revert.committed", (event) => {
      if (event.data.sessionID !== input.child().id) return
      mutate((value) =>
        value?.message && value.message.id >= event.data.to ? { ...value, message: undefined } : value,
      )
      setState("revision", (revision) => revision + 1)
    }),
  )
  // A step already running when the app connected may not have a cached row:
  // the data client drops its ending event rather than inventing its model.
  onCleanup(
    input.sdk.event.on("session.step.ended", (event) => {
      if (
        event.data.sessionID === input.child().id &&
        !input.data.session.message.get(input.child().id, event.data.assistantMessageID)
      )
        setState("revision", (revision) => revision + 1)
    }),
  )
  onCleanup(
    input.sdk.event.on("session.step.failed", (event) => {
      if (
        event.data.sessionID === input.child().id &&
        event.data.tokens &&
        !input.data.session.message.get(input.child().id, event.data.assistantMessageID)
      )
        setState("revision", (revision) => revision + 1)
    }),
  )
  createEffect(() => {
    if (!input.active() || input.sdk.connection.status() !== "connected") return
    void input.data.location.model.sync(input.child().location).catch(() => undefined)
  })
  return snapshot
}
