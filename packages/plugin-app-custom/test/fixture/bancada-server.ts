// A test server with this package's plugin, in a process of its own, for tests that need a server they can kill.
// `bun test/fixture/bancada-server.ts <folder>`: writes `<folder>/server.json` (`{ base, headers, project }`) once it
// listens.
// The environment comes from the test, whole: `bun run` does not load the test preload.
import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { Effect } from "effect"
import { startServer } from "../../../server/test/fixture/server"

const root = process.argv[2]
if (!root) throw new Error("usage: bancada-server.ts <folder>")
const project = path.join(root, "project")
const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../src/index.ts")).href
await fs.mkdir(path.join(project, ".opencode", "plugins"), { recursive: true })
await fs.writeFile(
  path.join(project, ".opencode", "plugins", "app-custom.ts"),
  `export { default } from ${JSON.stringify(plugin)}\n`,
)

Effect.runFork(
  Effect.scoped(
    Effect.gen(function* () {
      const server = yield* startServer(path.join(root, "config"))
      yield* Effect.promise(async () => {
        await Bun.write(path.join(root, "server.json.tmp"), JSON.stringify({ ...server, project }))
        await fs.rename(path.join(root, "server.json.tmp"), path.join(root, "server.json"))
      })
      return yield* Effect.never
    }),
  ),
)
