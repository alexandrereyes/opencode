import { closeSync, openSync } from "node:fs"
import fs from "node:fs/promises"
import type { Shell } from "../../../resources/adapters/android-lifecycle.js"
import { liveness } from "../launcher/process.js"

/** The machine as the device lifecycles reach it: commands with a deadline, detached processes, files. */
export function systemShell(): Shell {
  return {
    run: async (argv, options = {}) => {
      const child = Bun.spawn([...argv], {
        env: { ...process.env, ...options.env },
        stdin: options.stdin === undefined ? "ignore" : new Blob([options.stdin]),
        stdout: "pipe",
        stderr: "pipe",
        timeout: options.timeoutMs ?? 60_000,
      })
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ])
      return { code, stdout, stderr }
    },
    // In a session of its own: it outlives this process (a restart, a release) like an attempt's runner.
    detach: async (argv, options) => {
      const log = openSync(options.log, "w", 0o600)
      const child = Bun.spawn([...argv], {
        env: { ...process.env, ...options.env },
        detached: true,
        stdin: "ignore",
        stdout: log,
        stderr: log,
      })
      closeSync(log)
      child.unref()
      const life = await liveness(child.pid)
      return { pid: child.pid, ...(life.state === "alive" ? { started: life.started } : {}) }
    },
    alive: async (pid, started) => {
      const life = await liveness(pid)
      if (life.state !== "alive") return life.state
      return started === undefined || life.started === started ? "alive" : "dead"
    },
    signal: (pid, signal) => {
      try {
        process.kill(pid, signal)
      } catch {
        // Gone meanwhile.
      }
    },
    read: (file) =>
      Bun.file(file)
        .text()
        .catch(() => undefined),
    write: (file, text) => Bun.write(file, text).then(() => undefined),
    remove: (file) => fs.rm(file, { recursive: true, force: true }),
    sleep: (ms) => Bun.sleep(ms),
    now: () => Date.now(),
  }
}
