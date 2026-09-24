import { blobData, blobDataUrl } from "@/runtime/persistence/drafts"
import type { ImageAttachmentPart } from "../state"
import type { ComposerAttachment } from "../types"
import type { AttachmentDestination } from "./destination"
import { uploads } from "./uploads"

export { useAttachmentDestination, type AttachmentDestination } from "./destination"

export const MAX_INLINE_BYTES = 20 * 1024 * 1024

export function nativeAttachment(mime: string, size: number, input: AttachmentDestination["input"]) {
  if (size > MAX_INLINE_BYTES) return false
  if (["image/png", "image/jpeg", "image/gif", "image/webp"].includes(mime)) return input.image
  return mime === "application/pdf" && input.pdf
}

// Native media also gets a server path so tools can act on the file the model reads inline.
export type DeliveredAttachment =
  | { type: "inline"; attachment: ImageAttachmentPart; dataUrl: string; path: string }
  | { type: "path"; attachment: ComposerAttachment; path: string }

export function deliverAttachments(attachments: ComposerAttachment[], destination: AttachmentDestination) {
  return Promise.all(
    attachments.map(async (attachment): Promise<DeliveredAttachment> => {
      if (attachment.type === "path") return { type: "path", attachment, path: attachment.path }
      // Legacy drafts can still contain text or oversized blobs; migrate their delivery too.
      const blob = await blobData(attachment.blob)
      const path = await stage(attachment, blob, destination)
      if (nativeAttachment(attachment.mime, blob.size, destination.input)) {
        return { type: "inline", attachment, dataUrl: await blobDataUrl(attachment.blob, attachment.mime), path }
      }
      return { type: "path", attachment, path }
    }),
  )
}

async function stage(attachment: ImageAttachmentPart, blob: Blob, destination: AttachmentDestination) {
  if (destination.local && attachment.sourcePath) return attachment.sourcePath
  const file = new File([blob], attachment.filename, { type: attachment.mime })
  const path = await uploads.track(
    { id: crypto.randomUUID(), filename: file.name, mime: attachment.mime, size: file.size },
    (report, signal) => destination.upload(file, report, signal),
  )
  if (!path) throw new DOMException("Upload aborted", "AbortError")
  return path
}
