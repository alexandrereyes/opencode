import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { limits, makeBlobs } from "../src/bancada/daemon/blobs"

const roots: string[] = []
afterEach(() => Promise.all(roots.splice(0).map((root) => fs.rm(root, { recursive: true, force: true }))))

async function store(now = () => 1_000) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-blobs-"))
  roots.push(root)
  const blobs = makeBlobs({ root, now })
  const transfer = { id: "t0123456789abcdef", limitBytes: 3_000_000, fileLimitBytes: 2_800_000, expiresAt: 5_000 }
  await blobs.open(transfer)
  return { root, blobs, transfer }
}
const sha = (data: Uint8Array) => new Bun.CryptoHasher("sha256").update(data).digest("hex")
const content = Uint8Array.from({ length: 2_500_000 }, (_, index) => index % 251)
const file = { index: 0, path: "codigo.bundle", size: content.byteLength, sha256: sha(content) }

describe("blobs", () => {
  test("a file arrives in chunks, resumes from what was written, and counts only whole and with its SHA-256", async () => {
    const { blobs, transfer } = await store()
    const chunk = (offset: number) => content.subarray(offset, offset + limits.chunkBytes)
    expect(await blobs.put({ transfer: transfer.id, file, offset: 0, data: chunk(0), end: false })).toEqual({
      ok: true,
      received: limits.chunkBytes,
      done: false,
    })
    // A sender that lost the answer sends the first chunk again: told where to resume.
    expect(await blobs.put({ transfer: transfer.id, file, offset: 0, data: chunk(0), end: false })).toEqual({
      ok: false,
      reason: "offset",
      received: limits.chunkBytes,
    })
    expect(await blobs.get({ transfer: transfer.id, index: 0, offset: 0, size: 10 })).toEqual({
      ok: false,
      reason: "incomplete",
    })
    await blobs.put({
      transfer: transfer.id,
      file,
      offset: limits.chunkBytes,
      data: chunk(limits.chunkBytes),
      end: false,
    })
    const last = 2 * limits.chunkBytes
    expect(await blobs.put({ transfer: transfer.id, file, offset: last, data: chunk(last), end: true })).toEqual({
      ok: true,
      received: content.byteLength,
      done: true,
    })
    const parts: Uint8Array[] = []
    for (let offset = 0, end = false; !end; ) {
      const got = await blobs.get({ transfer: transfer.id, index: 0, offset, size: 4 * limits.chunkBytes })
      if (!got.ok) throw new Error(got.reason)
      expect(got.data.byteLength).toBeLessThanOrEqual(limits.chunkBytes)
      parts.push(got.data)
      offset += got.data.byteLength
      end = got.end
    }
    expect(sha(Buffer.concat(parts))).toBe(file.sha256)
  })

  test.each([
    ["a SHA-256 that does not match", { ...file, sha256: "0".repeat(64) }, content, "sha256"],
    ["a file above the file limit", { ...file, size: 2_900_000 }, content, "limit"],
    ["more bytes than declared", { ...file, size: 10 }, content.subarray(0, 11), "size"],
    ["a file shorter than declared at its end", { ...file, size: 20 }, content.subarray(0, 10), "size"],
  ])("refuses %s", async (_name, declared, data, reason) => {
    const { blobs, transfer } = await store()
    expect(await blobs.put({ transfer: transfer.id, file: declared, offset: 0, data, end: true })).toMatchObject({
      ok: false,
      reason,
    })
    expect(await blobs.file(transfer.id, 0)).toBeUndefined()
  })

  test("the files of a transfer together stay within its limit", async () => {
    const { blobs, transfer } = await store()
    const small = content.subarray(0, 100)
    await blobs.put({ transfer: transfer.id, file: { ...file, size: 2_000_000 }, offset: 0, data: small, end: false })
    expect(
      await blobs.put({
        transfer: transfer.id,
        file: { ...file, index: 1, size: 1_500_000 },
        offset: 0,
        data: small,
        end: false,
      }),
    ).toMatchObject({ ok: false, reason: "limit" })
  })

  test("an expired transfer refuses everything and is removed", async () => {
    let now = 1_000
    const { root, blobs, transfer } = await store(() => now)
    await blobs.put({
      transfer: transfer.id,
      file: { ...file, size: 3, sha256: sha(content.subarray(0, 3)) },
      offset: 0,
      data: content.subarray(0, 3),
      end: true,
    })
    now = 6_000
    expect(await blobs.get({ transfer: transfer.id, index: 0, offset: 0, size: 3 })).toEqual({
      ok: false,
      reason: "expired",
    })
    expect(await blobs.expire()).toBe(1)
    expect(await fs.readdir(root)).toEqual([])
    expect(await blobs.put({ transfer: "../../etc", file, offset: 0, data: content, end: true })).toMatchObject({
      ok: false,
      reason: "unknown",
    })
  })
})
