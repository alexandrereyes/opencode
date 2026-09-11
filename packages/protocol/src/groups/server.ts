import { Schema } from "effect"
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema, OpenApi } from "effect/unstable/httpapi"
import { NativeApp } from "@opencode/schema/native-app"
import { InvalidRequestError, ServiceUnavailableError } from "../errors.js"

export const ServerGroup = HttpApiGroup.make("server.server")
  .add(
    HttpApiEndpoint.get("server.nativeApps.list", "/api/server/native-apps", {
      success: NativeApp.Availability,
    }).annotateMerge(
      OpenApi.annotations({
        identifier: "v2.server.nativeApps.list",
        summary: "List native applications available on the server host",
      }),
    ),
    HttpApiEndpoint.post("server.nativeApps.open", "/api/server/native-apps/open", {
      payload: NativeApp.OpenInput,
      success: HttpApiSchema.NoContent,
      error: [InvalidRequestError, ServiceUnavailableError],
    }).annotateMerge(
      OpenApi.annotations({
        identifier: "v2.server.nativeApps.open",
        summary: "Open a host-local path in a known native application",
        description: "Launches on the server host, not on the browser's device. Currently supported on macOS only.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("server.subscriptions", "/api/server/subscriptions", {
      success: Schema.Struct({
        status: Schema.Literals(["ok", "unconfigured", "unavailable"]),
        accounts: Schema.Array(
          Schema.Struct({
            id: Schema.String,
            name: Schema.String,
            enabled: Schema.Boolean,
            plan: Schema.NullOr(Schema.String),
            authenticated: Schema.Boolean,
            cooldownSeconds: Schema.Number,
            bankedResets: Schema.NullOr(
              Schema.Struct({
                available: Schema.Number,
                earliestExpiresAt: Schema.NullOr(Schema.String),
                latestExpiresAt: Schema.NullOr(Schema.String),
                nonExpiring: Schema.Number,
              }),
            ),
            remaining: Schema.NullOr(Schema.Number),
            resetAt: Schema.NullOr(Schema.String),
            observedAt: Schema.NullOr(Schema.String),
            stale: Schema.Boolean,
            hasCapacity: Schema.NullOr(Schema.Boolean),
          }),
        ),
      }),
    }).annotateMerge(
      OpenApi.annotations({
        identifier: "v2.server.subscriptions",
        summary: "Read subscription quotas from the configured LLM proxy",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("server.get", "/api/server", {
      success: Schema.Struct({ urls: Schema.Array(Schema.String) }),
    }).annotateMerge(
      OpenApi.annotations({
        identifier: "v2.server.get",
        summary: "Get server information",
        description: "Return the URLs that can be used to connect to this server.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post("server.maintenance.acquire", "/api/server/maintenance", {
      success: Schema.Struct({
        lease: Schema.NullOr(
          Schema.Struct({ identity: Schema.String, token: Schema.String, expires: Schema.Number, pid: Schema.Number }),
        ),
        reason: Schema.String,
      }),
    }).annotateMerge(
      OpenApi.annotations({
        identifier: "v2.server.maintenance.acquire",
        summary: "Acquire an idle maintenance lease",
      }),
    ),
    HttpApiEndpoint.post("server.maintenance.cancel", "/api/server/maintenance/cancel", {
      payload: Schema.Struct({ token: Schema.String }),
      success: Schema.Struct({ cancelled: Schema.Boolean }),
    }).annotateMerge(
      OpenApi.annotations({ identifier: "v2.server.maintenance.cancel", summary: "Cancel a maintenance lease" }),
    ),
    HttpApiEndpoint.post("server.maintenance.commit", "/api/server/maintenance/commit", {
      payload: Schema.Struct({ token: Schema.String, identity: Schema.String }),
      success: Schema.Struct({ committed: Schema.Boolean }),
    }).annotateMerge(
      OpenApi.annotations({ identifier: "v2.server.maintenance.commit", summary: "Commit leased shutdown" }),
    ),
  )
  .annotateMerge(OpenApi.annotations({ title: "server" }))
