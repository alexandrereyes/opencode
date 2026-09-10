import { Schema } from "effect"
import { HttpApiEndpoint, HttpApiGroup, OpenApi } from "effect/unstable/httpapi"
import { Snippet } from "@opencode/schema/snippet"
import { ConflictError } from "../errors.js"

export const SnippetGroup = HttpApiGroup.make("server.snippet")
  .add(
    HttpApiEndpoint.get("snippet.list", "/api/snippet", {
      success: Schema.Array(Snippet.Info),
    }).annotateMerge(
      OpenApi.annotations({ identifier: "v2.snippet.list", summary: "List server-owned global and project snippets" }),
    ),
    HttpApiEndpoint.put("snippet.save", "/api/snippet", {
      payload: Snippet.Info,
      success: Snippet.Info,
      error: ConflictError,
    }).annotateMerge(
      OpenApi.annotations({ identifier: "v2.snippet.save", summary: "Create or replace a persistent snippet" }),
    ),
    HttpApiEndpoint.delete("snippet.remove", "/api/snippet/:id", {
      params: Schema.Struct({ id: Snippet.ID }),
      success: Schema.Void,
    }).annotateMerge(OpenApi.annotations({ identifier: "v2.snippet.remove", summary: "Remove a persistent snippet" })),
  )
  .annotateMerge(OpenApi.annotations({ title: "snippet" }))
