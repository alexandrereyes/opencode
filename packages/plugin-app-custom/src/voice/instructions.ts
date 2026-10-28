/// <reference path="../markdown.d.ts" />

import { Effect } from "effect"
import os from "node:os"
import path from "node:path"
import defaults from "./voice.md" with { type: "text" }

/** Read on every call; the editable file lives outside immutable releases. */
export function loadInstructions(
  file = path.join(
    process.env.OPENCODE_CONFIG_DIR ||
      path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"), "opencode"),
    "voice.md",
  ),
) {
  return Effect.tryPromise(async () => {
    const text = await Bun.file(file).text().catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return defaults
      throw error
    })
    if (!text.trim()) throw new Error("O prompt de voz em voice.md está vazio.")
    return text.trim()
  })
}
