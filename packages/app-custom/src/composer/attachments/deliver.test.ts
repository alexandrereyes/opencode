import { describe, expect, test } from "bun:test"
import type { ImageAttachmentPart } from "../state"
import { attachmentMime } from "./attachments"
import { deliverAttachments, type AttachmentDestination } from "./deliver"

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
  test("inlines text and only supported native media", async () => {
    const result = await deliverAttachments(
      [attachment("text/plain"), attachment("image/png"), attachment("application/pdf")],
      destination({ image: true, pdf: false }),
    )

    expect(result.map((item) => item.type)).toEqual(["inline", "inline", "path"])
    expect(result[2]).toMatchObject({ type: "path", path: "/remote/tmp/sample.bin" })
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
    const uploaded: { name: string; data: Uint8Array }[] = []
    const result = await deliverAttachments([attachment("application/zip")], {
      ...destination({ image: false, pdf: false }),
      upload: async (file) => {
        uploaded.push(file)
        return "/remote/tmp/archive.zip"
      },
    })

    expect([...uploaded[0]!.data]).toEqual([1, 2, 3])
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
  expect(await attachmentMime(new File([new Uint8Array([0, 1, 2])], "unknown.bin"))).toBe(
    "application/octet-stream",
  )
})
