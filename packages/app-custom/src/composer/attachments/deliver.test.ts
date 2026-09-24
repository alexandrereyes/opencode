import { describe, expect, test } from "bun:test"
import type { ImageAttachmentPart } from "../state"
import { attachmentMime } from "./attachments"
import { deliverAttachments, MAX_INLINE_BYTES, nativeAttachment, type AttachmentDestination } from "./deliver"
import { uploads } from "./uploads"
import { createDraftStore } from "@/runtime/persistence/drafts"

const attachment = (mime: string, sourcePath?: string): ImageAttachmentPart => ({
  type: "image",
  id: mime,
  filename: "sample.bin",
  sourcePath,
  mime,
  blob: { id: mime, url: "data:application/octet-stream;base64,AQID" },
})

const destination = (input: AttachmentDestination["input"], local = false): AttachmentDestination => ({
  input,
  local,
  upload: async () => "/remote/tmp/sample.bin",
})

describe("deliverAttachments", () => {
  test("staged paths require no bytes and oversized native media takes the path route", async () => {
    expect(nativeAttachment("image/png", MAX_INLINE_BYTES, { image: true, pdf: true })).toBe(true)
    expect(nativeAttachment("image/png", MAX_INLINE_BYTES + 1, { image: true, pdf: true })).toBe(false)
    const part = { type: "path" as const, id: "path", filename: "large.png", mime: "image/png", path: "/tmp/large.png" }
    expect(await deliverAttachments([part], destination({ image: true, pdf: true }))).toEqual([
      { type: "path", attachment: part, path: part.path },
    ])
  })

  test("tracks streamed upload progress and removes settled uploads", async () => {
    const gate = Promise.withResolvers<string>()
    const pending = uploads.track(
      { id: "large", filename: "large.zip", mime: "application/zip", size: 30000000 },
      async (report) => {
        report(15000000)
        return gate.promise
      },
    )
    expect(uploads.items().find((item) => item.id === "large")?.loaded).toBe(15000000)
    gate.resolve("/tmp/large.zip")
    expect(await pending).toBe("/tmp/large.zip")
    expect(uploads.items().some((item) => item.id === "large")).toBe(false)
  })

  test("legacy oversized native draft bytes are delivered by path", async () => {
    const blob = new Blob([new Uint8Array(MAX_INLINE_BYTES + 1)], { type: "image/png" })
    const store = createDraftStore({
      get: async () => null,
      set: async () => [],
      remove: async () => {},
      putBlob: async () => "legacy-large",
      getBlob: async () => blob,
    })
    const part = { ...attachment("image/png"), blob: await store.putBlob(blob) }
    const result = await deliverAttachments([part], {
      ...destination({ image: true, pdf: true }),
      upload: async (file) => {
        expect(file.size).toBe(MAX_INLINE_BYTES + 1)
        return "/tmp/legacy-large.png"
      },
    })
    expect(result[0]).toMatchObject({ type: "path", path: "/tmp/legacy-large.png" })
  })
  test("delivers text by path and only supported native media inline", async () => {
    const result = await deliverAttachments(
      [attachment("text/plain"), attachment("image/png"), attachment("application/pdf")],
      destination({ image: true, pdf: false }),
    )

    expect(result.map((item) => item.type)).toEqual(["path", "inline", "path"])
    expect(result[2]).toMatchObject({ type: "path", path: "/remote/tmp/sample.bin" })
  })

  test("stages native media on the server while keeping it inline", async () => {
    const uploaded: File[] = []
    const result = await deliverAttachments([attachment("application/pdf")], {
      ...destination({ image: true, pdf: true }),
      upload: async (file) => {
        uploaded.push(file)
        return "/remote/tmp/doc.pdf"
      },
    })

    expect(result[0]).toMatchObject({
      type: "inline",
      dataUrl: "data:application/pdf;base64,AQID",
      path: "/remote/tmp/doc.pdf",
    })
    expect([...new Uint8Array(await uploaded[0]!.arrayBuffer())]).toEqual([1, 2, 3])
  })

  test("uses a local source path for native media without uploading", async () => {
    const result = await deliverAttachments([attachment("image/png", "/local/photo.png")], {
      ...destination({ image: true, pdf: true }, true),
      upload: async () => {
        throw new Error("unexpected upload")
      },
    })

    expect(result[0]).toMatchObject({ type: "inline", path: "/local/photo.png" })
  })

  test("uses a local source path for unsupported media without uploading", async () => {
    let uploaded = false
    const result = await deliverAttachments([attachment("application/zip", "/local/archive.zip")], {
      ...destination({ image: false, pdf: false }, true),
      upload: async () => {
        uploaded = true
        return "/unused"
      },
    })

    expect(result).toEqual([
      { type: "path", attachment: attachment("application/zip", "/local/archive.zip"), path: "/local/archive.zip" },
    ])
    expect(uploaded).toBe(false)
  })

  test("uploads unsupported bytes for a remote destination", async () => {
    const uploaded: File[] = []
    const result = await deliverAttachments([attachment("application/zip")], {
      ...destination({ image: false, pdf: false }),
      upload: async (file) => {
        uploaded.push(file)
        return "/remote/tmp/archive.zip"
      },
    })

    expect([...new Uint8Array(await uploaded[0]!.arrayBuffer())]).toEqual([1, 2, 3])
    expect(result[0]).toMatchObject({ type: "path", path: "/remote/tmp/archive.zip" })
  })

  test("propagates upload failures", async () => {
    const error = new Error("upload failed")
    await expect(
      deliverAttachments([attachment("application/zip")], {
        ...destination({ image: false, pdf: false }),
        upload: async () => {
          throw error
        },
      }),
    ).rejects.toBe(error)
  })
})

test("generic binary attachments preserve their MIME type", async () => {
  expect(await attachmentMime(new File([new Uint8Array([0, 1, 2])], "archive.zip", { type: "application/zip" }))).toBe(
    "application/zip",
  )
  expect(await attachmentMime(new File([new Uint8Array([0, 1, 2])], "unknown.bin"))).toBe("application/octet-stream")
})
