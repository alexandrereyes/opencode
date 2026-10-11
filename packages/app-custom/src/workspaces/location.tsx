import { createSimpleContext } from "@opencode/ui-custom/context"
import { isLocationNotFoundError, type LocationGetOutput, type LocationRef } from "@opencode/client/promise"
import { retry } from "@opencode/util/retry"
import { type Accessor, createEffect, createMemo, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import { type LocationContext, useServerSDK } from "@/runtime/server/client"
import { useData, useServer } from "@/runtime/server/current"
export type { LocationContext } from "@/runtime/server/client"

export type WorkspaceLocation = LocationContext & {
  readonly ref: LocationRef
  readonly current: LocationGetOutput | undefined
  /** Set only when the server reports that this exact Location's folder does not exist. */
  readonly missing: LocationRef | undefined
}

const context = createSimpleContext({
  name: "Location",
  init: (props: { directory: string | Accessor<string>; workspaceID?: string | Accessor<string | undefined> }) => {
    const serverSDK = useServerSDK()
    const server = useServer()
    const data = useData()
    const ref = createMemo(
      () => ({
        directory: typeof props.directory === "function" ? props.directory() : props.directory,
        workspaceID: typeof props.workspaceID === "function" ? props.workspaceID() : props.workspaceID,
      }),
      undefined,
      {
        equals: (previous, next) => previous.directory === next.directory && previous.workspaceID === next.workspaceID,
      },
    )
    const current = createMemo(() => data.location.info(ref()))
    const [state, setState] = createStore<{ missing?: LocationRef }>({})

    createEffect(() => {
      const location = ref()
      let stale = false
      onCleanup(() => {
        stale = true
      })
      setState("missing", undefined)
      if (serverSDK.connection.status() !== "connected") return
      // Generic sync failures do not prove the directory is missing; only the server's typed
      // LocationNotFoundError does, and retrying it cannot succeed until the folder changes. The custom
      // directory guard skips a folder the plugin reports missing instead of failing, so its answer counts too.
      void retry(() => (stale ? Promise.resolve() : data.location.sync(location)), {
        retryIf: (error) => !stale && !isLocationNotFoundError(error),
      })
        .then(() => server.ctx.directories.available(location.directory))
        .then(
          (available) => {
            if (!stale && !available) setState("missing", location)
          },
          (error) => {
            if (stale || !isLocationNotFoundError(error)) return
            setState("missing", location)
          },
        )
    })
    createEffect(() => {
      const id = current()?.project.id
      if (!id || serverSDK.connection.status() !== "connected") return
      // Showing a Location is the demand for its project's worktree inventory (workspace styling, picker).
      // Key it by the metadata root so the result merges into the same global project record.
      const root = server.ctx.sync.data.project.find((project) => project.id === id)?.worktree
      if (root) void server.ctx.sync.worktrees.load(id, root)
    })

    const location = createMemo(() => serverSDK.ensureDirSdkContext(current()?.directory ?? ref().directory))
    return createMemo<WorkspaceLocation>(() => ({
      ...location(),
      ref: ref(),
      current: current(),
      missing: state.missing,
    }))
  },
})

export const useWorkspaceLocation: () => Accessor<WorkspaceLocation> = context.use
export const LocationProvider = context.provider
