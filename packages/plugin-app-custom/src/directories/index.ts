import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { Directories } from "./rpc.js"

export const registerDirectories = Effect.fn("Directories.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(Directories.Definition, {
      home: () => Effect.succeed({ path: os.homedir() }),
      create: (input, context) =>
        Effect.promise(() => createDirectory(input.path)).pipe(
          Effect.flatMap((result) =>
            typeof result === "string"
              ? Effect.fail(context.error("create_failed", message(result), { reason: result }))
              : Effect.succeed(result),
          ),
        ),
    })
    .pipe(Effect.orDie)
})

// Creates only the final segment so a mistyped parent never produces an unintended directory tree.
export async function createDirectory(target: string): Promise<{ path: string } | Directories.CreateFailure> {
  if (!path.isAbsolute(target)) return "invalid-path"
  const normalized = path.resolve(target)
  if (normalized === path.parse(normalized).root) return "invalid-path"
  return fs.mkdir(normalized).then(
    () => ({ path: normalized }),
    (error: NodeJS.ErrnoException) => failure(error.code),
  )
}

function failure(code: string | undefined): Directories.CreateFailure {
  if (code === "EEXIST") return "exists"
  if (code === "ENOENT") return "missing-parent"
  if (code === "EACCES" || code === "EPERM" || code === "EROFS") return "denied"
  if (code === "ENOTDIR") return "invalid-path"
  return "failed"
}

function message(reason: Directories.CreateFailure) {
  if (reason === "invalid-path") return "The target must be an absolute directory path"
  if (reason === "exists") return "The directory already exists"
  if (reason === "missing-parent") return "The parent directory does not exist"
  if (reason === "denied") return "Permission denied"
  return "The directory could not be created"
}
