import { describe, expect } from "bun:test"
import { Effect, Schema } from "effect"
import { Snippet } from "@opencode/core/snippet"
import { Project } from "@opencode/schema/project"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { testEffect } from "./lib/effect"

const it = testEffect(LayerNode.compile(Snippet.node))
const global = Snippet.Info.make({
  id: "review",
  name: "review",
  description: "Review code",
  aliases: ["audit"],
  content: "Check correctness.\nRun tests.",
})

describe("server snippets", () => {
  it.effect("stores and updates global and project snippets, preserves concurrent writes, and deletes by ID", () =>
    Effect.gen(function* () {
      const snippets = yield* Snippet.Service
      expect(yield* snippets.list()).toEqual([])
      yield* Effect.all(
        [
          snippets.save(global),
          snippets.save({ ...global, id: "local", project: Project.ID.make("repo") }),
          snippets.save({ ...global, id: "other", name: "other" }),
        ],
        { concurrency: "unbounded" },
      )
      expect(yield* snippets.list()).toHaveLength(3)
      yield* snippets.save({ ...global, name: "renamed", content: "New content" })
      expect((yield* snippets.list()).find((item) => item.id === global.id)?.content).toBe("New content")
      const conflict = yield* snippets.save({ ...global, id: "duplicate", name: "RENAMED" }).pipe(Effect.flip)
      expect(conflict._tag).toBe("SnippetConflictError")
      yield* snippets.remove("local")
      yield* snippets.remove("local")
      expect((yield* snippets.list()).map((item) => item.id).sort()).toEqual(["other", "review"])
    }),
  )

  it.effect("validates content and names and omits absent project from storage", () =>
    Effect.sync(() => {
      expect(Schema.encodeSync(Snippet.Info)(global)).not.toHaveProperty("project")
      expect(() => Schema.decodeUnknownSync(Snippet.Info)({ ...global, content: "   " })).toThrow()
      expect(() => Schema.decodeUnknownSync(Snippet.Info)({ ...global, name: "#review" })).toThrow()
      expect(() => Schema.decodeUnknownSync(Snippet.Info)({ ...global, name: "two words" })).toThrow()
    }),
  )
})
