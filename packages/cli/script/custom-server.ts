import { NodeRuntime, NodeServices } from "@effect/platform-node"
import { Effect } from "effect"
import { ServerProcess } from "@opencode/server/process"
import { WebUi } from "../src/services/web-ui"
import type { AssetMap } from "../src/app-assets"
import { HttpServer } from "effect/unstable/http"
import path from "node:path"

const root = process.env.OPENCODE_CUSTOM_HOME
const version = process.env.OPENCODE_CUSTOM_COMMIT
if (!root || !version) throw new Error("Run this entrypoint through opencode-custom")
const password = await Bun.file(`${root}/password`).text()
const plugin = path.resolve("packages/plugin-app-custom/dist")
const assets: AssetMap = Object.fromEntries(
  await Promise.all(
    Array.from(new Bun.Glob("**/*").scanSync({ cwd: "packages/app/dist", onlyFiles: true })).map(async (name) => [
      name,
      new Uint8Array(await Bun.file(`packages/app/dist/${name}`).arrayBuffer()),
    ]),
  ),
)

NodeRuntime.runMain(
  Effect.scoped(
    Effect.gen(function* () {
      const transform = yield* WebUi.handler({ assets })
      const server = yield* ServerProcess.start(
        {
          app: { name: "opencode-custom", version, channel: "custom" },
          hostname: "127.0.0.1",
          port: Number(process.env.OPENCODE_CUSTOM_PORT ?? "4177"),
          password: password.trim(),
          database: { path: process.env.OPENCODE_CUSTOM_DB ?? `${root}/data/opencode/custom.db` },
          config: {
            directory: process.env.OPENCODE_CONFIG_DIR ?? `${root}/config/opencode`,
            project: process.env.OPENCODE_CUSTOM_SMOKE !== "1",
            content: JSON.stringify({ plugins: [plugin] }),
          },
          models: { fetch: process.env.OPENCODE_CUSTOM_SMOKE !== "1" },
        },
        {
          onListen: (address) =>
            Effect.promise(async () => {
              await Bun.write(
                `${root}/server.json`,
                JSON.stringify({ url: HttpServer.formatAddress(address), pid: process.pid, version }),
              )
              return Effect.void
            }),
        },
        transform,
      )
      // A supervisor crash closes this private pipe, so an orphan cannot keep serving an old release.
      const parentClosed = Effect.callback<void>((resume) => {
        const end = () => resume(Effect.void)
        process.stdin.once("end", end)
        process.stdin.resume()
        return Effect.sync(() => {
          process.stdin.off("end", end)
          process.stdin.pause()
        })
      })
      yield* Effect.raceFirst(server.shutdown, parentClosed)
    }),
  ).pipe(Effect.provide(NodeServices.layer)),
)
