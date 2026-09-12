import { $ } from "bun"
import { expect } from "bun:test"
import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { OpenCode } from "@opencode/client"
import { Worktrees } from "@opencode/plugin-app-custom/worktrees/rpc"
import { AbsolutePath } from "@opencode/schema/schema"
import { Effect } from "effect"
import { HttpServer } from "effect/unstable/http"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { ServerProcess } from "../src/process"

it.live("serves custom worktree deletion while preserving native routes", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-plugin-worktrees-http-")
    const project = path.join(tmp.path, "project")
    const linked = path.join(tmp.path, "linked")
    const destination = path.join(tmp.path, "created")
    const config = path.join(tmp.path, "config")
    const pluginPackage = path.join(tmp.path, "plugin")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
    yield* Effect.promise(async () => {
      await Promise.all([project, config, pluginPackage].map((directory) => fs.mkdir(directory, { recursive: true })))
      await $`git init`.cwd(project).quiet()
      await $`git config user.email test@opencode.test`.cwd(project).quiet()
      await $`git config user.name Test`.cwd(project).quiet()
      await $`git commit --allow-empty -m root`.cwd(project).quiet()
      await $`git branch feature`.cwd(project).quiet()
      await $`git worktree add ${linked} feature`.cwd(project).quiet()
      await fs.writeFile(
        path.join(pluginPackage, "package.json"),
        JSON.stringify({ type: "module", exports: "./index.ts" }),
      )
      await fs.writeFile(path.join(pluginPackage, "index.ts"), `export { default } from ${JSON.stringify(plugin)}\n`)
    })
    yield* Effect.scoped(
      Effect.gen(function* () {
        const server = yield* ServerProcess.start<never, never>({
          hostname: "127.0.0.1",
          port: 0,
          password: "secret",
          app: { version: "test" },
          database: { path: path.join(tmp.path, "test.db") },
          config: { directory: config, content: JSON.stringify({ plugins: [pluginPackage] }) },
          models: { fetch: false },
          fs: { filewatcher: false },
        })
        const baseUrl = HttpServer.formatAddress(server.address)
        const headers = { authorization: `Basic ${btoa("opencode:secret")}` }
        const client = OpenCode.make({ baseUrl, headers })
        const worktrees = client.rpc(Worktrees.Definition)
        yield* Effect.promise(() => client.plugin.awaitActivation({ location: { directory: project } }))
        expect(
          (yield* Effect.promise(() => client.plugin.list({ location: { directory: project } }))).data.find(
            (item) => item.id === "custom.app-mentions",
          ),
        ).toMatchObject({ state: { status: "active" } })
        yield* Effect.promise(() => client.worktree.list({ location: { directory: project } }))
        const inspection = yield* Effect.promise(() =>
          worktrees.inspect({ directory: linked }, { location: { directory: project } }),
        )
        yield* Effect.promise(() => fs.writeFile(path.join(linked, "dirty.txt"), "dirty"))
        const failure = yield* Effect.tryPromise({
          try: () =>
            worktrees.delete(
              { directory: linked, force: false, identity: inspection.identity, branch: inspection.branch ?? null },
              { location: { directory: project } },
            ),
          catch: (error) => error,
        }).pipe(Effect.flip)
        expect(failure).toMatchObject({ type: "operation_failed", data: { forceRequired: true } })
        expect(
          yield* Effect.promise(() =>
            worktrees.delete(
              { directory: linked, force: true, identity: inspection.identity, branch: inspection.branch ?? null },
              { location: { directory: project } },
            ),
          ),
        ).toEqual({ directory: AbsolutePath.make(linked) })

        const created = yield* Effect.promise(() =>
          client.worktree.create({ location: { directory: project }, directory: destination, name: "native" }),
        )
        yield* Effect.promise(() =>
          client.worktree.remove({ location: { directory: project }, directory: created.directory, force: false }),
        )
        const inspectUrl = new URL("/api/worktree/inspect", baseUrl)
        inspectUrl.searchParams.set("location[directory]", project)
        inspectUrl.searchParams.set("directory", linked)
        const deleteUrl = new URL("/api/worktree/delete", baseUrl)
        deleteUrl.searchParams.set("location[directory]", project)
        const old = yield* Effect.promise(() =>
          Promise.all([
            fetch(inspectUrl, { headers }),
            fetch(deleteUrl, {
              method: "DELETE",
              headers: { ...headers, "content-type": "application/json" },
              body: JSON.stringify({
                directory: linked,
                force: true,
                identity: inspection.identity,
                branch: inspection.branch ?? null,
              }),
            }),
          ]),
        )
        expect(old.map((response) => response.status)).toEqual([404, 404])
        yield* Effect.promise(() => Promise.all(old.map((response) => response.arrayBuffer())))
      }),
    )
  }).pipe(Effect.timeout("30 seconds")),
)
