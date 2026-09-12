import { Schema } from "effect"
import { HttpApiEndpoint, HttpApiGroup, OpenApi } from "effect/unstable/httpapi"

export const ServerGroup = HttpApiGroup.make("server.server")
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
