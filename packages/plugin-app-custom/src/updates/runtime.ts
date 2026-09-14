import { Schema } from "effect"
import { realpath } from "node:fs/promises"
import path from "node:path"
import { Service } from "@opencode/client/effect/service"
import { PtyHandoff } from "@opencode/client/pty-handoff"
import { Updates } from "./rpc.js"
import { createExecutor } from "./executor.js"
import { readRelease } from "./release.js"

// Packaged as a node_modules dependency, which the native local-plugin loader
// deliberately excludes from hot-reload invalidation. Every Location shares it.
const executors = new Map<string, Promise<ReturnType<typeof createExecutor>>>()

export function executorFor(home: string, commit: string, version: string) {
  const key = path.resolve(home)
  const existing = executors.get(key)
  if (existing) return existing
  const executor = load(key, commit, version)
  executors.set(key, executor)
  return executor
}

async function load(home: string, commit: string, version: string) {
  const running = Schema.decodeUnknownSync(Updates.Target)({ commit, version })
  const executable = await realpath(process.execPath)
  if (executable !== path.join(await realpath(home), "releases", commit, "bin/opencode"))
    throw new Error("Custom updates require the launchd release executable")
  if (!(await readRelease(home, "current"))) throw new Error("Missing active release")
  return createExecutor({
    home,
    running,
    prepareRestart: async () => {
      const file = path.join(home, "state/opencode/service-custom.json")
      const info = Schema.decodeUnknownSync(Schema.fromJsonString(Service.Info))(await Bun.file(file).text())
      if (info.pid !== process.pid) throw new Error("This process does not own the registered launchd service")
      await PtyHandoff.prepare(file, info, 10_000)
    },
    // NodeRuntime closes the native server scopes on SIGTERM. Never process.exit.
    shutdown: () => process.kill(process.pid, "SIGTERM"),
  })
}
