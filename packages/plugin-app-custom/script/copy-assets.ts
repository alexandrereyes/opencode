import { copyFile, mkdir } from "node:fs/promises"
import path from "node:path"

// tsc emits JavaScript only. Text imports (`import x from "./file.md" with { type: "text" }`) and any other
// non-TypeScript source must sit beside the compiled modules in dist, or the dist plugin fails to load.
// The release bundles src with Bun instead, which embeds them.
const root = path.join(import.meta.dir, "..")
await Promise.all(
  Array.from(new Bun.Glob("**/*").scanSync({ cwd: path.join(root, "src"), onlyFiles: true }))
    .filter((file) => !/\.(?:c|m)?tsx?$/.test(file))
    .map(async (file) => {
      await mkdir(path.dirname(path.join(root, "dist", file)), { recursive: true })
      await copyFile(path.join(root, "src", file), path.join(root, "dist", file))
    }),
)
