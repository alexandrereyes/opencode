import type { Endpoint } from "@opencode/client/service"
import type { run } from "@opencode/tui"
import { pathToFileURL } from "node:url"
import path from "node:path"

type UpdateSource = NonNullable<Parameters<typeof run>[0]["updater"]>

/** A trusted, host-selected adapter for deployments whose updater lives outside this CLI. */
export async function loadTuiUpdater(file: string, endpoint: Endpoint): Promise<UpdateSource> {
  const module = await import(pathToFileURL(path.resolve(file)).href)
  if (typeof module.createUpdater !== "function") throw new Error("TUI updater must export createUpdater")
  const source: unknown = await module.createUpdater({ endpoint })
  if (!isUpdateSource(source)) throw new Error("Invalid TUI updater adapter")
  return source
}

function isUpdateSource(value: unknown): value is UpdateSource {
  return (
    typeof value === "object" &&
    value !== null &&
    "remote" in value &&
    typeof value.remote === "boolean" &&
    "subscribe" in value &&
    typeof value.subscribe === "function" &&
    "check" in value &&
    typeof value.check === "function" &&
    "apply" in value &&
    typeof value.apply === "function"
  )
}
