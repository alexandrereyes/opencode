import { Schema } from "effect"
import { createHash, randomUUID } from "node:crypto"
import { createReadStream } from "node:fs"
import { lstat, realpath, rename, symlink, unlink } from "node:fs/promises"
import path from "node:path"
import { Updates } from "./rpc.js"

export const artifacts = [
  "bin/opencode",
  "plugin/index.js",
  "plugin/tui.js",
  "plugin/prepare.js",
  "plugin/handoff.js",
  "plugin/node_modules/@opencode/plugin-app-custom/package.json",
  "plugin/node_modules/@opencode/plugin-app-custom/runtime.js",
  "server-config.json",
] as const
const digest = Schema.String.check(Schema.isPattern(/^[a-f0-9]{64}$/))
export const Manifest = Schema.Struct({
  format: Schema.Literal(1),
  ...Updates.Target.fields,
  platform: Schema.Literal("darwin"),
  arch: Schema.Literals(["arm64", "x64"]),
  files: Schema.Struct({
    "bin/opencode": digest,
    "plugin/index.js": digest,
    "plugin/tui.js": digest,
    "plugin/prepare.js": digest,
    "plugin/handoff.js": digest,
    "plugin/node_modules/@opencode/plugin-app-custom/package.json": digest,
    "plugin/node_modules/@opencode/plugin-app-custom/runtime.js": digest,
    "server-config.json": digest,
  }),
})
export type Manifest = typeof Manifest.Type
const decode = Schema.decodeUnknownSync(Schema.fromJsonString(Manifest))

export async function readRelease(home: string, name: "current" | "prepared", verify = false) {
  const pointer = path.join(home, name)
  if (
    !(await lstat(pointer).catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return undefined
      throw error
    }))
  )
    return
  const directory = await realpath(pointer)
  const manifest = await readManifest(directory, verify)
  if (directory !== path.join(await realpath(home), "releases", manifest.commit))
    throw new Error(`Release pointer escapes its release directory: ${name}`)
  return manifest
}

export async function readManifest(directory: string, verify = false) {
  const manifest = decode(await Bun.file(path.join(directory, "manifest.json")).text())
  if (manifest.platform !== process.platform || manifest.arch !== process.arch)
    throw new Error("Release does not match this host")
  if (verify)
    await Promise.all(
      artifacts.map(async (name) => {
        const file = path.join(directory, name)
        if (!(await lstat(file)).isFile()) throw new Error(`Release artifact is not a regular file: ${name}`)
        if ((await sha256(file)) !== manifest.files[name]) throw new Error(`Release checksum mismatch: ${name}`)
      }),
    )
  return manifest
}

export async function sha256(file: string) {
  const hash = createHash("sha256")
  for await (const chunk of createReadStream(file)) hash.update(chunk)
  return hash.digest("hex")
}

/** Only explicit activation writes current. Preparation always writes prepared. */
export async function pointRelease(home: string, name: "current" | "prepared", commit: string) {
  Schema.decodeUnknownSync(Updates.Target.fields.commit)(commit)
  const temporary = path.join(home, `.${name}-${randomUUID()}`)
  await symlink(path.join("releases", commit), temporary)
  await rename(temporary, path.join(home, name)).finally(() => unlink(temporary).catch(() => undefined))
}
