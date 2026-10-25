import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { Effect } from "effect"
import { HttpServer } from "effect/http"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { ServerProcess } from "../src/process"

it.live("the first shell in a cold Location runs after plugins register their shell hooks", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-shell-endpoint-")
    const config = path.join(tmp.path, "config")
    const location = path.join(tmp.path, "location")
    const pluginPackage = path.join(tmp.path, "plugin")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin/src/effect/index.ts")).href
    const effect = pathToFileURL(Bun.resolveSync("effect", import.meta.dir)).href
    yield* Effect.promise(async () => {
      await Promise.all([config, location, pluginPackage].map((directory) => fs.mkdir(directory, { recursive: true })))
      await fs.writeFile(path.join(location, "opencode.json"), "{}")
      await fs.writeFile(
        path.join(pluginPackage, "package.json"),
        JSON.stringify({ type: "module", exports: "./index.ts" }),
      )
      // Activation takes a while before the hook exists, as a plugin with many registrations does.
      await fs.writeFile(
        path.join(pluginPackage, "index.ts"),
        [
          `import { Plugin } from ${JSON.stringify(plugin)}`,
          `import { Effect } from ${JSON.stringify(effect)}`,
          `export default Plugin.define({`,
          `  id: "test.shell-hook",`,
          `  effect: (ctx) => Effect.gen(function* () {`,
          `    yield* Effect.sleep("300 millis")`,
          `    yield* ctx.shell.hook("create.before", (input) => Effect.sync(() => { input.env.SHELL_HOOK_MARK = "ready" }))`,
          `  }),`,
          `})`,
        ].join("\n"),
      )
    })
    const server = yield* ServerProcess.start<never, never>({
      hostname: "127.0.0.1",
      port: 0,
      password: "secret",
      app: { version: "test" },
      database: { path: ":memory:" },
      config: { directory: config, content: JSON.stringify({ plugins: [pluginPackage] }) },
      models: { fetch: false },
      fs: { filewatcher: false },
    })
    const base = HttpServer.formatAddress(server.address)
    const headers = { authorization: `Basic ${btoa("opencode:secret")}`, "content-type": "application/json" }
    const query = `location[directory]=${encodeURIComponent(location)}`

    const created = yield* Effect.promise(() =>
      fetch(`${base}/api/shell?${query}`, {
        method: "POST",
        headers,
        body: JSON.stringify({ command: 'printf "%s" "$SHELL_HOOK_MARK"', cwd: location }),
      }).then((response) => response.json() as Promise<{ data: { id: string } }>),
    )
    const output = yield* Effect.promise(async () => {
      const deadline = Date.now() + 10_000
      while (Date.now() < deadline) {
        const shell = (await (await fetch(`${base}/api/shell/${created.data.id}?${query}`, { headers })).json()) as {
          data: { status: string }
        }
        if (shell.data.status !== "running") break
        await Bun.sleep(20)
      }
      const page = (await (await fetch(`${base}/api/shell/${created.data.id}/output?${query}`, { headers })).json()) as {
        data: { output: string }
      }
      return page.data.output
    })
    expect(output).toBe("ready")
  }),
)
