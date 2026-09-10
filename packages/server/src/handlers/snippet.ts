import { Effect } from "effect"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { Snippet } from "@opencode/core/snippet"
import { ConflictError } from "@opencode/protocol/errors"
import { Api } from "../api"

export const SnippetHandler = HttpApiBuilder.group(Api, "server.snippet", (handlers) =>
  handlers
    .handle("snippet.list", () => Snippet.Service.use((snippets) => snippets.list()))
    .handle("snippet.save", ({ payload }) =>
      Snippet.Service.use((snippets) => snippets.save(payload)).pipe(
        Effect.mapError(
          () =>
            new ConflictError({
              message: "A snippet with this name already exists in this scope.",
              resource: "snippet",
            }),
        ),
      ),
    )
    .handle("snippet.remove", ({ params }) => Snippet.Service.use((snippets) => snippets.remove(params.id))),
)
