import { Effect } from "effect"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { Api } from "../api"
import { ServerInfo } from "../server-info"
import { Maintenance } from "@opencode/core/maintenance"
import { PersistentPty } from "@opencode/core/persistent-pty"
import { Job } from "@opencode/core/job"
import { JobMaintenance } from "@opencode/core/job-maintenance"
import { Session } from "@opencode/core/session"
import { SessionExecution } from "@opencode/core/session/execution"
import { Instance } from "@opencode/core/instance/service"
import { Shell } from "@opencode/core/shell"
import { ID } from "@opencode/schema/shell"
import { Database } from "@opencode/core/database/database"
import { SessionInboxTable } from "@opencode/core/session/sql"
import { readSubscriptions } from "../subscriptions"

export const ServerHandler = HttpApiBuilder.group(Api, "server.server", (handlers) =>
  handlers
    .handle("server.subscriptions", () => readSubscriptions())
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
          const sessions = yield* Session.Service
          const execution = yield* SessionExecution.Service
          const instances = yield* Instance.Service
          // These checks run behind the admission barrier. Unknown terminal state refuses activation.
          const reason =
            (yield* terminals.list()).length > 0
              ? "open-terminals"
              : (yield* JobMaintenance.pending({
                    jobs,
                    activity: (recovery) =>
                      Effect.gen(function* () {
                        if (recovery.kind === "subagent")
                          return (yield* execution.isActive(recovery.childSessionID))
                            ? ("running" as const)
                            : ("ended" as const)
                        const session = yield* sessions.get(recovery.sessionID)
                        return yield* Effect.gen(function* () {
                          const shell = yield* Shell.Service
                          return yield* shell.get(ID.make(recovery.shellID))
                        }).pipe(
                          instances.provide(session),
                          Effect.map((info) => (info.status === "running" ? ("running" as const) : ("ended" as const))),
                          Effect.catchTag("Shell.NotFoundError", () => Effect.succeed("missing" as const)),
                        )
                      }),
                  }))
                ? "background-notification"
                : (yield* database.db.select().from(SessionInboxTable).limit(1)).length > 0
                  ? "pending-inbox"
                  : undefined
          const pending = reason !== undefined
          if (pending) {
            Maintenance.process.cancel(lease.token)
            return { lease: null, reason }
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
