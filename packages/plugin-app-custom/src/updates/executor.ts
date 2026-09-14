import { Flock } from "@opencode/util/flock"
import path from "node:path"
import { Updates } from "./rpc.js"
import { pointRelease, readRelease } from "./release.js"

export function createExecutor(input: {
  home: string
  running: Updates.Target
  prepareRestart: () => Promise<void>
  shutdown: () => void
}) {
  let stopping = false
  return {
    async check(): Promise<Updates.State> {
      const current = await readRelease(input.home, "current")
      if (!current) return { status: "disabled" }
      if (current.commit !== input.running.commit)
        return { status: stopping ? "installing" : "ready", ...target(current) }
      const prepared = await readRelease(input.home, "prepared")
      if (!prepared || prepared.commit === current.commit) return { status: "up-to-date" }
      return { status: "ready", ...target(prepared) }
    },
    async install(expected: Updates.Target) {
      return Flock.withLock(
        "activation",
        async () => {
          const current = await readRelease(input.home, "current")
          if (!current) throw new Error("Bootstrap an initial release before activating updates")
          // A retried confirmation can re-arm shutdown after a disconnected HTTP response.
          if (current.commit === expected.commit && current.version === expected.version) {
            if (current.commit !== input.running.commit) await input.prepareRestart()
            return target(current)
          }
          if (current.commit !== input.running.commit || current.version !== input.running.version)
            throw new Error("Another release has already been selected; wait for the service to restart")
          const prepared = await readRelease(input.home, "prepared", true)
          if (!prepared || prepared.commit !== expected.commit || prepared.version !== expected.version)
            throw new Error("The prepared release changed. Check for updates again before confirming")
          await input.prepareRestart()
          await pointRelease(input.home, "current", prepared.commit)
          return target(prepared)
        },
        { dir: path.join(input.home, "locks"), timeoutMs: 10_000 },
      )
    },
    shutdown: () => {
      if (stopping) return
      stopping = true
      input.shutdown()
    },
  }
}

function target(value: Updates.Target): Updates.Target {
  return { commit: value.commit, version: value.version }
}
