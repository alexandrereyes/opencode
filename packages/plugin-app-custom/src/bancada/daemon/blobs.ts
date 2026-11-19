import { createReadStream } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"

/**
 * Temporary files that travel through the hub (`docs/bancada.md`, "Blobs"): a request's code bundle or the evidence
 * of its failures. One folder per transfer under `<state>/blobs/`, written in chunks straight to disk, each file
 * checked against its declared size and SHA-256 before it counts; the folder goes at cleanup or when it expires.
 * Who may write or read a transfer is the caller's business (the hub's RPC); this module only keeps the bytes.
 */

export type Transfer = {
  /** 128 random bits, made by the hub. */
  readonly id: string
  /** Every file of the transfer together may not pass this. */
  readonly limitBytes: number
  readonly fileLimitBytes: number
  readonly expiresAt: number
}

export type File = { readonly index: number; readonly path: string; readonly size: number; readonly sha256: string }

export type Put =
  | { readonly ok: true; readonly received: number; readonly done: boolean }
  | {
      readonly ok: false
      readonly reason: "unknown" | "expired" | "offset" | "limit" | "size" | "sha256"
      readonly received?: number
    }

export type Got =
  | { readonly ok: true; readonly data: Uint8Array; readonly end: boolean }
  | { readonly ok: false; readonly reason: "unknown" | "expired" | "incomplete" }

type Meta = Transfer & { readonly files: Record<string, File> }

export const limits = { chunkBytes: 1024 * 1024 }

const id = /^[A-Za-z0-9_-]{16,64}$/

export function makeBlobs(input: { readonly root: string; readonly now: () => number }) {
  const folder = (transfer: string) => path.join(input.root, transfer)
  const metaFile = (transfer: string) => path.join(folder(transfer), "meta.json")
  const part = (transfer: string, index: number) => path.join(folder(transfer), `${index}.part`)
  const done = (transfer: string, index: number) => path.join(folder(transfer), String(index))

  const meta = async (transfer: string): Promise<Meta | undefined> => {
    if (!id.test(transfer)) return undefined
    return Bun.file(metaFile(transfer))
      .json()
      .catch(() => undefined)
  }
  const size = (file: string) =>
    fs.stat(file).then(
      (stat) => stat.size,
      () => 0,
    )

  return {
    /** Opens a transfer; opening it again changes nothing. */
    open: async (transfer: Transfer) => {
      if (!id.test(transfer.id)) throw new Error("invalid transfer id")
      if (await meta(transfer.id)) return
      await fs.mkdir(folder(transfer.id), { recursive: true, mode: 0o700 })
      await Bun.write(metaFile(transfer.id), JSON.stringify({ ...transfer, files: {} } satisfies Meta), { mode: 0o600 })
    },

    /**
     * Writes a chunk of a file at `offset`, which must be what is already written (otherwise the answer says how much
     * is, so the sender resumes from there). With `end`, the file must have its declared size and SHA-256; only then
     * it counts as received.
     */
    put: async (request: {
      readonly transfer: string
      readonly file: File
      readonly offset: number
      readonly data: Uint8Array
      readonly end: boolean
    }): Promise<Put> => {
      const known = await meta(request.transfer)
      if (!known) return { ok: false, reason: "unknown" }
      if (input.now() > known.expiresAt) return { ok: false, reason: "expired" }
      const target = done(request.transfer, request.file.index)
      if (await fs.exists(target)) return { ok: true, received: await size(target), done: true }
      const others = Object.values(known.files).filter((file) => file.index !== request.file.index)
      const total = others.reduce((sum, file) => sum + file.size, 0) + request.file.size
      if (request.file.size > known.fileLimitBytes || total > known.limitBytes) return { ok: false, reason: "limit" }
      const partial = part(request.transfer, request.file.index)
      const written = await size(partial)
      if (request.offset !== written) return { ok: false, reason: "offset", received: written }
      if (written + request.data.byteLength > request.file.size) return { ok: false, reason: "size", received: written }
      if (!known.files[request.file.index])
        await Bun.write(
          metaFile(request.transfer),
          JSON.stringify({ ...known, files: { ...known.files, [request.file.index]: request.file } } satisfies Meta),
        )
      await fs.appendFile(partial, request.data, { mode: 0o600 })
      const received = written + request.data.byteLength
      if (!request.end) return { ok: true, received, done: false }
      if (received !== request.file.size) return { ok: false, reason: "size", received }
      if ((await sha256(partial)) !== request.file.sha256) {
        await fs.rm(partial, { force: true })
        return { ok: false, reason: "sha256", received: 0 }
      }
      await fs.rename(partial, target)
      return { ok: true, received, done: true }
    },

    /** Reads `size` bytes of a received file from `offset`; `end` says this reaches its last byte. */
    get: async (request: {
      readonly transfer: string
      readonly index: number
      readonly offset: number
      readonly size: number
    }): Promise<Got> => {
      const known = await meta(request.transfer)
      if (!known) return { ok: false, reason: "unknown" }
      if (input.now() > known.expiresAt) return { ok: false, reason: "expired" }
      const target = done(request.transfer, request.index)
      if (!(await fs.exists(target))) return { ok: false, reason: "incomplete" }
      const length = Math.min(request.size, limits.chunkBytes)
      const total = await size(target)
      const data = new Uint8Array(
        await Bun.file(target)
          .slice(request.offset, request.offset + length)
          .arrayBuffer(),
      )
      return { ok: true, data, end: request.offset + data.byteLength >= total }
    },

    /** Where a received file is, for a copy on this machine. */
    file: async (transfer: string, index: number) => {
      const target = done(transfer, index)
      return (await meta(transfer)) && (await fs.exists(target)) ? target : undefined
    },

    remove: (transfer: string) =>
      id.test(transfer) ? fs.rm(folder(transfer), { recursive: true, force: true }) : Promise.resolve(),

    /** Removes the transfers that expired; returns how many. */
    expire: async () => {
      const names = await fs.readdir(input.root).catch(() => [] as string[])
      const expired = await Promise.all(
        names.map(async (name) => {
          const known = await meta(name)
          return known && input.now() > known.expiresAt ? [name] : []
        }),
      )
      await Promise.all(expired.flat().map((name) => fs.rm(folder(name), { recursive: true, force: true })))
      return expired.flat().length
    },
  }
}

export type Blobs = ReturnType<typeof makeBlobs>

/** SHA-256 of a file, read as a stream (a code bundle may be large). */
export async function sha256(file: string) {
  const hasher = new Bun.CryptoHasher("sha256")
  for await (const chunk of createReadStream(file)) hasher.update(chunk as Buffer)
  return hasher.digest("hex")
}
