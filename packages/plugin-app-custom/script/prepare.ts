import path from "node:path"
import { prepare } from "../src/updates/prepare.js"
import { readRelease } from "../src/updates/release.js"
import { syncUpstream } from "../src/updates/upstream-sync.js"

const home = process.argv[2]
if (!home || !path.isAbsolute(home)) throw new Error("Usage: prepare.ts <absolute-distribution-home>")
if (await readRelease(home, "current")) {
  const sync = await syncUpstream(home)
  if (sync.status === "blocked") {
    console.log(`Upstream synchronization blocked (${sync.reason}); release preparation skipped.`)
    process.exit(0)
  }
}
const release = await prepare(home)
console.log(`Prepared ${release.version} (${release.commit}); activation requires explicit confirmation.`)
