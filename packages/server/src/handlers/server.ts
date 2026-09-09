import { Effect } from "effect"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { Api } from "../api"
import { ServerInfo } from "../server-info"
import { Maintenance } from "@opencode/core/maintenance"
import { PersistentPty } from "@opencode/core/persistent-pty"
import { Job } from "@opencode/core/job"
import { Database } from "@opencode/core/database/database"
import { SessionInboxTable } from "@opencode/core/session/sql"

export const ServerHandler = HttpApiBuilder.group(Api, "server.server", (handlers) =>
  handlers
    .handle("server.get", () =>
      Effect.gen(function* () {
        const info = yield* ServerInfo.Service
        return { urls: info.urls() }
      }),
    )
    .handle("server.maintenance.acquire", () =>
      Effect.gen(function* () {
        const info = yield* ServerInfo.Service
        if (!info.shutdown) return { lease: null, reason: "unsupported" }
        const lease = Maintenance.process.lease()
        if (!lease) return { lease: null, reason: "busy" }
        return yield* Effect.gen(function* () {
          const terminals = yield* PersistentPty.Service
          const jobs = yield* Job.Service
          const database = yield* Database.Service
          // These checks run behind the admission barrier. Unknown terminal state refuses activation.
          const pending =
            (yield* terminals.list()).length > 0 ||
            (yield* jobs.pendingBackground).length > 0 ||
            (yield* database.db.select().from(SessionInboxTable).limit(1)).length > 0
          if (pending) {
            Maintenance.process.cancel(lease.token)
            return { lease: null, reason: "pending-work" }
          }
          return { lease: { ...lease, pid: process.pid }, reason: "idle" }
        }).pipe(
          Effect.catchCause(() => {
            Maintenance.process.cancel(lease.token)
            return Effect.succeed({ lease: null, reason: "unknown" })
          }),
        )
      }),
    )
    .handle("server.maintenance.cancel", ({ payload }) =>
      Effect.sync(() => ({ cancelled: Maintenance.process.cancel(payload.token) })),
    )
    .handle("server.maintenance.commit", ({ payload }) =>
      Effect.gen(function* () {
        const info = yield* ServerInfo.Service
        if (!info.shutdown) return { committed: false }
        const committed = Maintenance.process.commit(payload.token, payload.identity)
        if (committed) info.shutdown()
        return { committed }
      }),
    ),
)
